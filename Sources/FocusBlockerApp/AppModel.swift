import AppKit
import FocusCore
import Foundation
import ServiceManagement

/// Bridges the SwiftUI views to `FocusEngine`. The engine stays the single authority: the app only calls it,
/// so closing or quitting the app never changes a session. The native host and focusctl share the same state.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state = FocusState()
    @Published private(set) var policy = EnforcementPolicy.inactive
    @Published private(set) var heartbeat: BrowserHeartbeat?
    @Published private(set) var startupError: String?
    /// Whether the background agent, which closes blocked apps and browsers, is allowed to run.
    @Published private(set) var agentEnabled = true
    @Published var errorMessage: String?
    @Published var notice: String?

    let stateDirectory: URL
    private(set) var audit: AuditLog?
    private var engine: FocusEngine?
    private var timer: Timer?
    private let clock = SystemClock()

    init(stateDirectory: URL = FocusPaths.stateDirectory) {
        self.stateDirectory = stateDirectory
        do {
            (engine, audit) = try FocusPaths.makeEngine(stateDirectory: stateDirectory)
        } catch {
            startupError = String(describing: error)
        }
        AgentController.reRegisterIfUpdated()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard let engine else { return }
        do {
            try engine.tick()
        } catch {
            errorMessage = describe(error)
        }
        state = engine.state
        policy = engine.policy()
        heartbeat = HeartbeatStore(directory: stateDirectory).read()
        agentEnabled = SMAppService.agent(plistName: AgentController.plistName).status == .enabled
    }

    /// Runs an engine action, refreshes, and reports the outcome. Returns whether it succeeded.
    @discardableResult
    func perform(_ success: String? = nil, _ action: (FocusEngine) throws -> Void) -> Bool {
        guard let engine else {
            errorMessage = startupError ?? "The engine isn't available."
            return false
        }
        do {
            try action(engine)
            errorMessage = nil
            notice = success
            refresh()
            return true
        } catch {
            errorMessage = describe(error)
            notice = nil
            refresh()
            return false
        }
    }

    func describe(_ error: Error) -> String {
        (error as? FocusError)?.description ?? String(describing: error)
    }

    // MARK: Derived values

    var activeSessions: [Session] { state.activeSessions }
    var isActive: Bool { !activeSessions.isEmpty }
    var longestRemaining: TimeInterval { activeSessions.map(\.remaining).max() ?? 0 }
    var sortedBlocklists: [Blocklist] { state.blocklists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }

    func names(for ids: [UUID]) -> String {
        let byID = Dictionary(uniqueKeysWithValues: state.blocklists.map { ($0.id, $0.name) })
        return ids.compactMap { byID[$0] }.joined(separator: ", ")
    }

    func isLocked(_ list: Blocklist) -> Bool {
        activeSessions.contains { $0.strict && $0.blocklistIDs.contains(list.id) }
    }

    var hostManifestInstalled: Bool {
        let url = NativeHostManifest.chromeDirectory().appendingPathComponent(NativeHostManifest.name + ".json")
        return FileManager.default.fileExists(atPath: url.path)
    }

    var heartbeatAge: TimeInterval? { heartbeat.map { $0.age(clock: clock) } }

    /// The extension counts as connected if it reported within two heartbeat intervals.
    var chromeConnected: Bool { (heartbeatAge ?? .infinity) < 35 }

    func auditEntries() -> [AuditEntry] { (try? audit?.entries()) ?? [] }
}

enum Format {
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func minutes(_ minuteOfDay: Int) -> String {
        String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }

    static let weekdaySymbols = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
}
