import AppKit
import FocusCore
import Security
import UserNotifications

// focus-agent: the per-user background process. Runs from the app bundle as a LaunchAgent (registered with
// SMAppService), or directly for testing. Each second it advances the engine, closes apps that the active session
// blocks, closes Chrome during strict sessions when the Focus extension isn't working, closes other browsers
// during strict sessions that block websites, and posts notifications about all of it.
//
// It only ever asks apps to quit (the same as ⌘Q) and never force-quits, so unsaved work can't be lost. An app that
// stays open, for example behind a save dialog, is hidden and asked again every 10 seconds.

func log(_ text: String) { NSLog("focus-agent: %@", text) }

final class Agent {
    let engine: FocusEngine
    let audit: AuditLog
    let stateDirectory: URL
    let heartbeats: HeartbeatStore
    let clock = SystemClock()
    /// When each app was last asked to quit, by process ID.
    var quitRequests: [pid_t: Date] = [:]
    let retryInterval: TimeInterval = 10
    let notifier = Notifier()
    var sessionChanges = SessionChangeTracker()
    /// Last "app closed" notification per bundle ID, so relaunching an app repeatedly doesn't flood notifications.
    var lastClosedNotice: [String: Date] = [:]

    init(stateDirectory: URL) throws {
        self.stateDirectory = stateDirectory
        (engine, audit) = try FocusPaths.makeEngine(stateDirectory: stateDirectory)
        heartbeats = HeartbeatStore(directory: stateDirectory)
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
        log("started; state in \(stateDirectory.path)")
    }

    func tick() {
        do {
            try engine.tick()
        } catch {
            log("engine error: \(error)")
        }
        announceSessionChanges()
        let policy = engine.policy()
        let running = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != getpid() && !$0.isTerminated }
        quitRequests = quitRequests.filter { pid, _ in running.contains { $0.processIdentifier == pid } }
        guard policy.active else { return }

        for app in running {
            if let reason = reasonToClose(app, policy: policy) { close(app, reason: reason) }
        }
    }

    func reasonToClose(_ app: NSRunningApplication, policy: EnforcementPolicy) -> String? {
        guard let bundleID = app.bundleIdentifier else { return nil }
        let needsTeam = policy.blockedApps.contains { $0.bundleID == bundleID && $0.teamID != nil }
        let info = RunningAppInfo(pid: app.processIdentifier, bundleID: bundleID,
                                  teamID: needsTeam ? teamID(of: app.processIdentifier) : nil)
        if AppGuard.blockingRule(for: info, policy: policy) != nil { return "blocked during this focus session" }

        if let reason = BrowserGuard.reasonToCloseOtherBrowser(bundleID, policy: policy,
                                                                enabled: engine.state.settings.closeOtherBrowsers) {
            return reason
        }

        guard BrowserGuard.chromeBundleIDs.contains(bundleID) else { return nil }
        let observation = BrowserGuard.Observation(
            hostInstalled: hostInstalled,
            heartbeatAge: heartbeats.read().map { $0.age(clock: clock) },
            runningFor: app.launchDate.map { Date().timeIntervalSince($0) } ?? .infinity,
            launchedWithExtensionsDisabled: arguments(of: app.processIdentifier).contains { $0.hasPrefix("--disable-extensions") },
            isStableChrome: bundleID == "com.google.Chrome")
        return BrowserGuard.reasonToClose(observation, policy: policy, gracePeriod: engine.state.settings.extensionGracePeriod)
    }

    func close(_ app: NSRunningApplication, reason: String) {
        let pid = app.processIdentifier
        let name = app.localizedName ?? app.bundleIdentifier ?? "app"
        if let last = quitRequests[pid] {
            // Still open: keep it out of the way, and ask again periodically.
            if !app.isHidden { app.hide() }
            guard Date().timeIntervalSince(last) >= retryInterval else { return }
        } else {
            log("closing \(name): \(reason)")
            try? audit.append("app.closed", "\(app.bundleIdentifier ?? name): \(reason)", at: Date())
            let key = app.bundleIdentifier ?? name
            if Date().timeIntervalSince(lastClosedNotice[key] ?? .distantPast) > 30 {
                lastClosedNotice[key] = Date()
                notifier.post(FocusNotice.closed(appName: name, reason: reason, until: engine.policy().estimatedEnd), id: "closed-\(key)")
            }
        }
        quitRequests[pid] = Date()
        app.terminate()
    }

    func announceSessionChanges() {
        let names = Dictionary(uniqueKeysWithValues: engine.state.blocklists.map { ($0.id, $0.name) })
        let listNames: (Session) -> String = { $0.blocklistIDs.compactMap { names[$0] }.joined(separator: ", ") }
        let (started, ended) = sessionChanges.update(engine.state)
        for session in started { notifier.post(FocusNotice.started(session, listNames: listNames(session)), id: "start-\(session.id)") }
        for session in ended { notifier.post(FocusNotice.ended(session, listNames: listNames(session)), id: "end-\(session.id)") }
    }

    var hostInstalled: Bool {
        let manifest = NativeHostManifest.chromeDirectory().appendingPathComponent(NativeHostManifest.name + ".json")
        return FileManager.default.fileExists(atPath: manifest.path)
    }
}

/// Posts local notifications. macOS asks once whether Focus Blocker may show them; if that's declined, or
/// notifications aren't available, the agent keeps working and only logs.
final class Notifier {
    private var center: UNUserNotificationCenter?

    init() {
        // Notifications need a real app bundle; a bare test binary has none.
        guard Bundle.main.bundleIdentifier != nil else {
            log("no app bundle: notifications disabled")
            return
        }
        center = UNUserNotificationCenter.current()
        center?.requestAuthorization(options: [.alert, .sound]) { granted, error in
            log("notifications \(granted ? "allowed" : "not allowed")\(error.map { ": \($0.localizedDescription)" } ?? "")")
        }
    }

    func post(_ notice: FocusNotice.Content, id: String) {
        log("notice: \(notice.title) — \(notice.body)")
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { log("notification failed: \(error.localizedDescription)") }
        }
    }
}

/// Team identifier from the running process's code signature.
func teamID(of pid: pid_t) -> String? {
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
          let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
    return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
}

/// Command-line arguments of a process owned by this user, read with KERN_PROCARGS2.
func arguments(of pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
    let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
    var i = 4
    while i < size && buffer[i] != 0 { i += 1 }  // executable path
    while i < size && buffer[i] == 0 { i += 1 }  // padding
    var args: [String] = []
    while args.count < argc && i < size {
        let start = i
        while i < size && buffer[i] != 0 { i += 1 }
        args.append(String(decoding: buffer[start..<i], as: UTF8.self))
        i += 1
    }
    return args
}

/// Only one agent per state folder; launchd's copy and a manually started one must not both act.
func acquireSingleInstanceLock(in directory: URL) -> Bool {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let fd = open(directory.appendingPathComponent(".agent.lock").path, O_RDWR | O_CREAT, 0o600)
    return fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0  // Held until the process exits.
}

let stateDirectory = FocusPaths.stateDirectory
guard acquireSingleInstanceLock(in: stateDirectory) else {
    log("another agent is already running for \(stateDirectory.path)")
    exit(0)
}
do {
    // A background app with no Dock icon or menu bar, so it can be a proper notification sender.
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let agent = try Agent(stateDirectory: stateDirectory)
    agent.start()
    withExtendedLifetime(agent) { application.run() }
} catch {
    log("could not start: \(error)")
    exit(1)
}
