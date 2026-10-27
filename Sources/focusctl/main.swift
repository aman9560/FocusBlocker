import Foundation
import FocusCore

let usage = """
focusctl — command-line front end for the Focus blocker engine

  status [--json]
  blocklist list
  blocklist create NAME [--domain D]... [--except D]... [--app BUNDLE_ID]...
  blocklist add NAME [--domain D]... [--except D]... [--app BUNDLE_ID]...
  blocklist remove NAME [--domain D]... [--except D]... [--app BUNDLE_ID]...
  blocklist delete NAME
  password set
  start --blocklist NAME [--blocklist NAME]... --minutes N [--lock timer|password|none] [--no-strict]
  stop
  failsafe-end     end active sessions immediately; preserve all configuration
  schedule list
  schedule add NAME --blocklist NAME... --days mon,tue|weekdays|all --from HH:MM --to HH:MM [--tz ZONE] [--lock L] [--no-strict]
  schedule delete NAME
  tick | run
  policy [--json]
  chrome-rules
  audit [--verify]
  import FILE [--into NAME] [--dry-run]   (Cold Turkey JSON export, or one site per line)
  settings close-other-browsers on|off
  chrome status
  chrome extension-id PATH/TO/manifest.json
  chrome install-host --extension-id ID [--dry-run]
  chrome uninstall-host

Options: --state-dir DIR (default ~/Library/Application Support/FocusBlocker; also FOCUS_STATE_DIR)
         --key-file FILE  (default STATE_DIR/state.key; also FOCUS_KEY_FILE)
         --password-stdin (read passwords from stdin, one per line)
Sessions default to a strict, timer-locked session. `failsafe-end` is an explicit emergency override.
"""

struct Arguments {
    var positional: [String] = []
    var options: [String: [String]] = [:]
    var flags: Set<String> = []

    static let valued: Set<String> = ["--state-dir", "--key-file", "--domain", "--except", "--app", "--blocklist", "--minutes",
                                      "--lock", "--days", "--from", "--to", "--tz", "--extension-id", "--into"]

    init(_ raw: [String]) throws {
        var i = 0
        while i < raw.count {
            let arg = raw[i]
            if Self.valued.contains(arg) {
                guard i + 1 < raw.count else { throw CLIError("\(arg) needs a value") }
                options[arg, default: []].append(raw[i + 1])
                i += 2
            } else if arg.hasPrefix("--") {
                flags.insert(arg)
                i += 1
            } else {
                positional.append(arg)
                i += 1
            }
        }
    }

    func one(_ key: String) -> String? { options[key]?.last }
    func many(_ key: String) -> [String] { options[key] ?? [] }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

final class PasswordReader {
    let fromStdin: Bool
    init(fromStdin: Bool) { self.fromStdin = fromStdin }

    func read(_ prompt: String) throws -> String {
        if fromStdin {
            guard let line = readLine(strippingNewline: true) else { throw CLIError("expected a password on stdin") }
            return line
        }
        var buffer = [CChar](repeating: 0, count: 512)
        guard let result = readpassphrase(prompt + ": ", &buffer, buffer.count, RPP_REQUIRE_TTY) else {
            throw CLIError("no terminal to read the password from; use --password-stdin")
        }
        return String(cString: result)
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded(.up))
    return String(format: "%dh %02dm %02ds", s / 3600, (s % 3600) / 60, s % 60)
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

func run() throws {
    let args = try Arguments(Array(CommandLine.arguments.dropFirst()))
    guard let command = args.positional.first, !args.flags.contains("--help") else {
        print(usage)
        return
    }

    let stateDir = args.one("--state-dir").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? FocusPaths.stateDirectory
    let keyFile = args.one("--key-file").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    let (engine, audit) = try FocusPaths.makeEngine(stateDirectory: stateDir, keyFile: keyFile)
    let passwords = PasswordReader(fromStdin: args.flags.contains("--password-stdin"))
    let sub = args.positional.dropFirst().first

    for event in try engine.tick() { report(event) }

    switch (command, sub) {
    case ("status", _):
        let policy = engine.policy()
        if args.flags.contains("--json") {
            try printJSON(StatusReport(policy: policy, sessions: engine.state.activeSessions,
                                       passwordSet: engine.state.accountability != nil))
            return
        }
        let names = Dictionary(uniqueKeysWithValues: engine.state.blocklists.map { ($0.id, $0.name) })
        if engine.state.activeSessions.isEmpty { print("No active sessions.") }
        for s in engine.state.activeSessions {
            let lists = s.blocklistIDs.compactMap { names[$0] }.joined(separator: ", ")
            let origin: String
            if case .scheduled = s.origin { origin = "scheduled" } else { origin = "manual" }
            print("● \(lists) — \(formatDuration(s.remaining)) left, lock \(s.lock.rawValue)\(s.strict ? ", strict" : ""), \(origin)")
        }
        print("Accountability password: \(engine.state.accountability == nil ? "not set" : "set")")
        print("Close other browsers during strict sessions: \(engine.state.settings.closeOtherBrowsers ? "on" : "off")")
        if engine.state.limiter.isLockedOut { print("Unlock attempts locked for \(formatDuration(engine.state.limiter.lockoutRemaining)).") }

    case ("blocklist", "list"):
        if engine.state.blocklists.isEmpty { print("No blocklists.") }
        for list in engine.state.blocklists.sorted(by: { $0.name < $1.name }) {
            print("\(list.name)")
            if !list.domains.isEmpty { print("  block:  \(list.domains.joined(separator: " "))") }
            if !list.exceptions.isEmpty { print("  except: \(list.exceptions.joined(separator: " "))") }
            if !list.apps.isEmpty { print("  apps:   \(list.apps.map(\.bundleID).joined(separator: " "))") }
        }

    case ("blocklist", "create"):
        let name = try argument(args, 2, "NAME")
        try engine.createBlocklist(name: name, domains: args.many("--domain"), exceptions: args.many("--except"),
                                   apps: args.many("--app").map { AppRule(bundleID: $0) })
        print("Created blocklist \(name).")

    case ("blocklist", "add"), ("blocklist", "remove"):
        var list = try engine.blocklist(named: try argument(args, 2, "NAME"))
        let adding = sub == "add"
        let domains = try DomainRule.normalize(args.many("--domain"))
        let exceptions = try DomainRule.normalize(args.many("--except"))
        let apps = args.many("--app").map { AppRule(bundleID: $0) }
        if adding {
            list.domains += domains
            list.exceptions += exceptions
            list.apps += apps.filter { !list.apps.contains($0) }
        } else {
            list.domains.removeAll { domains.contains($0) }
            list.exceptions.removeAll { exceptions.contains($0) }
            list.apps.removeAll { apps.contains($0) }
        }
        try engine.updateBlocklist(list)
        print("Updated blocklist \(list.name).")

    case ("blocklist", "delete"):
        try engine.deleteBlocklist(named: try argument(args, 2, "NAME"))
        print("Deleted.")

    case ("password", "set"):
        let current = engine.state.accountability == nil ? nil : try passwords.read("Current accountability password")
        let new = try passwords.read("New accountability password")
        if !args.flags.contains("--password-stdin") {
            guard try passwords.read("Repeat new password") == new else { throw CLIError("passwords don't match") }
        }
        try engine.setAccountabilityPassword(new, current: current)
        print("Accountability password saved.")

    case ("start", _):
        guard let minutes = args.one("--minutes").flatMap(Double.init) else { throw CLIError("--minutes N is required") }
        let lockName = args.one("--lock") ?? "timer"
        guard let lock = LockKind(rawValue: lockName) else { throw CLIError("--lock must be timer, password or none") }
        let session = try engine.startSession(blocklistNames: args.many("--blocklist"), duration: minutes * 60,
                                              lock: lock, strict: !args.flags.contains("--no-strict"))
        print("Session started: \(formatDuration(session.duration)), lock \(lock.rawValue)\(session.strict ? ", strict" : "").")
        if lock == .timer { print("Normal stop is disabled; failsafe-end remains available.") }

    case ("stop", _):
        let needsPassword = engine.state.activeSessions.contains { $0.lock == .password }
            && !engine.state.activeSessions.contains { $0.lock == .timer }
        let password = needsPassword ? try passwords.read("Accountability password") : nil
        let ended = try engine.stopSessions(password: password)
        print(ended.isEmpty ? "No active sessions." : "Stopped \(ended.count) session(s).")

    case ("failsafe-end", _):
        print("End all active FocusBlocker sessions now? Blocklists and settings will be preserved. (y/N)", terminator: " ")
        guard readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "y" else {
            print("Cancelled.")
            return
        }
        let ended = try engine.endSessionsWithFailsafe()
        print(ended.isEmpty ? "No active sessions." : "Failsafe ended \(ended.count) session(s); blocklists and settings were preserved.")

    case ("schedule", "list"):
        let names = Dictionary(uniqueKeysWithValues: engine.state.blocklists.map { ($0.id, $0.name) })
        if engine.state.schedules.isEmpty { print("No schedules.") }
        for rule in engine.state.schedules {
            let days = rule.weekdays.sorted().map { ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][$0] }.joined(separator: ",")
            let time = String(format: "%02d:%02d–%02d:%02d", rule.startMinute / 60, rule.startMinute % 60, rule.endMinute / 60, rule.endMinute % 60)
            print("\(rule.name): \(days) \(time) \(rule.timeZoneID) → \(rule.blocklistIDs.compactMap { names[$0] }.joined(separator: ", ")), lock \(rule.lock.rawValue)\(rule.strict ? ", strict" : "")\(rule.enabled ? "" : " (disabled)")")
        }

    case ("schedule", "add"):
        let name = try argument(args, 2, "NAME")
        guard let days = args.one("--days"), let from = args.one("--from"), let to = args.one("--to") else {
            throw CLIError("--days, --from and --to are required")
        }
        guard let lock = LockKind(rawValue: args.one("--lock") ?? "timer") else { throw CLIError("--lock must be timer, password or none") }
        let ids = try args.many("--blocklist").map { try engine.blocklist(named: $0).id }
        try engine.upsertSchedule(ScheduleRule(name: name, blocklistIDs: ids, weekdays: try Weekday.parse(days),
                                               startMinute: try Weekday.parseTime(from), endMinute: try Weekday.parseTime(to),
                                               timeZoneID: args.one("--tz") ?? TimeZone.current.identifier,
                                               lock: lock, strict: !args.flags.contains("--no-strict")))
        print("Saved schedule \(name).")

    case ("schedule", "delete"):
        try engine.deleteSchedule(named: try argument(args, 2, "NAME"))
        print("Deleted.")

    case ("tick", _):
        break

    case ("run", _):
        print("Ticking every second. Ctrl-C to stop.")
        while true {
            Thread.sleep(forTimeInterval: 1)
            for event in try engine.tick() { report(event) }
        }

    case ("policy", _):
        let policy = engine.policy()
        if args.flags.contains("--json") {
            try printJSON(policy)
        } else if !policy.active {
            print("Nothing is blocked.")
        } else {
            print("Blocking \(policy.blockedDomains.count) site rule(s), \(policy.blockedApps.count) app(s); strict \(policy.strict); revision \(policy.revision)")
            policy.blockedDomains.forEach { print("  block  \($0)") }
            policy.exceptions.forEach { print("  allow  \($0)") }
            policy.blockedApps.forEach { print("  app    \($0.bundleID)") }
        }

    case ("chrome-rules", _):
        print(String(decoding: try ChromeRuleCompiler.json(for: engine.policy()), as: UTF8.self))

    case ("audit", _):
        if args.flags.contains("--verify") {
            switch try audit.verify() {
            case .intact(let count): print("Audit log intact (\(count) entries).")
            case .broken(let line, let reason):
                print("Audit log BROKEN at line \(line): \(reason)")
                exit(2)
            }
        } else {
            let formatter = ISO8601DateFormatter()
            for entry in try audit.entries() { print("\(formatter.string(from: entry.time))  \(entry.event)  \(entry.detail)") }
        }

    case ("import", _):
        let path = try argument(args, 1, "FILE")
        let blocks = try BlocklistImport.load(Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)))
        let dryRun = args.flags.contains("--dry-run")
        for block in blocks {
            let target = block.targetName(override: args.one("--into"))
            print("\(target): \(block.result.domains.count) site(s), \(block.result.exceptions.count) exception(s)")
            block.result.domains.forEach { print("  block  \($0)") }
            block.result.exceptions.forEach { print("  allow  \($0)") }
            block.result.skipped.forEach { print("  skip   \($0) (not a website rule)") }
            if !dryRun { try engine.importRules(block.result, intoBlocklistNamed: target) }
        }
        print(dryRun ? "(dry run: nothing imported)" : "Imported.")

    case ("settings", "close-other-browsers"):
        guard let value = args.positional.dropFirst(2).first, ["on", "off"].contains(value) else {
            throw CLIError("usage: settings close-other-browsers on|off")
        }
        try engine.setCloseOtherBrowsers(value == "on")
        print("Close other browsers during strict sessions: \(value).")

    case ("chrome", "status"):
        let manifestURL = NativeHostManifest.chromeDirectory().appendingPathComponent(NativeHostManifest.name + ".json")
        print("Host manifest: \(FileManager.default.fileExists(atPath: manifestURL.path) ? manifestURL.path : "not installed")")
        guard let beat = HeartbeatStore(directory: stateDir).read() else {
            print("No heartbeat from the extension yet.")
            return
        }
        let age = beat.age(clock: SystemClock())
        print("Last heartbeat: \(age.isFinite ? "\(Int(age)) s ago" : "before the last reboot") from \(beat.extensionOrigin) v\(beat.extensionVersion)")
        print("Rules in Chrome: \(beat.ruleCount), revision \(beat.rulesRevision) (\(beat.rulesRevision == engine.policy().revision ? "current" : "out of date"))")
        print("Allowed in incognito: \(beat.incognitoAllowed ? "yes" : "NO. Enable it in chrome://extensions, or incognito windows are unfiltered")")

    case ("chrome", "extension-id"):
        let path = try argument(args, 2, "MANIFEST")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
        guard let key = manifest?["key"] as? String, let id = NativeHostManifest.extensionID(publicKeyBase64: key) else {
            throw CLIError("\(path) has no valid \"key\"")
        }
        print(id)

    case ("chrome", "install-host"):
        guard let id = args.one("--extension-id"), NativeHostManifest.isValidExtensionID(id) else {
            throw CLIError("--extension-id must be a 32-letter Chrome extension ID")
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("focus-nmh")
        let hostURL = FocusPaths.installedHost(in: stateDir)
        let manifestDir = NativeHostManifest.chromeDirectory()
        let manifestURL = manifestDir.appendingPathComponent(NativeHostManifest.name + ".json")
        let contents = try NativeHostManifest.contents(hostPath: hostURL.path, extensionIDs: [id])
        guard FileManager.default.isExecutableFile(atPath: source.path) else { throw CLIError("\(source.path) not found; run ./build.sh first") }

        print("Copy  \(source.path)\n  ->  \(hostURL.path)")
        print("Write \(manifestURL.path):\n\(String(decoding: contents, as: UTF8.self))")
        if args.flags.contains("--dry-run") {
            print("(dry run: nothing written)")
            return
        }
        let fm = FileManager.default
        try fm.createDirectory(at: hostURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: hostURL.path) { try fm.removeItem(at: hostURL) }
        try fm.copyItem(at: source, to: hostURL)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hostURL.path)
        try fm.createDirectory(at: manifestDir, withIntermediateDirectories: true)
        try contents.write(to: manifestURL, options: .atomic)
        try audit.append("chrome.host.installed", id, at: Date())
        print("Installed. Reload the extension in chrome://extensions.")

    case ("chrome", "uninstall-host"):
        if engine.state.activeSessions.contains(where: \.strict) {
            throw CLIError("not during a strict session")
        }
        let manifestURL = NativeHostManifest.chromeDirectory().appendingPathComponent(NativeHostManifest.name + ".json")
        try? FileManager.default.removeItem(at: manifestURL)
        try? FileManager.default.removeItem(at: FocusPaths.installedHost(in: stateDir))
        try audit.append("chrome.host.uninstalled", "", at: Date())
        print("Removed \(manifestURL.path) and the installed host.")

    default:
        throw CLIError("unknown command. Run focusctl --help.")
    }
}

struct StatusReport: Encodable {
    let policy: EnforcementPolicy
    let sessions: [Session]
    let passwordSet: Bool
}

func argument(_ args: Arguments, _ index: Int, _ name: String) throws -> String {
    guard args.positional.count > index else { throw CLIError("\(name) is required") }
    return args.positional[index]
}

func report(_ event: EngineEvent) {
    switch event {
    case .sessionStarted(let s): print("→ scheduled session started (\(formatDuration(s.duration)))")
    case .sessionEnded: print("→ session completed")
    case .clockAnomaly(let a): print("→ clock change detected: \(a)")
    case .recoveredFromBackup(let why): print("→ recovered state from backup: \(why)")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("focusctl: \(error)\n".utf8))
    exit(1)
}
