import CryptoKit
import FocusCore
import ServiceManagement
import SwiftUI

/// Registers the bundled LaunchAgent with launchd through SMAppService. macOS lists it under
/// System Settings › General › Login Items, where it can be allowed or turned off.
@MainActor
final class AgentController: ObservableObject {
    static let plistName = "com.focusblocker.agent.plist"
    @Published private(set) var status: SMAppService.Status = .notRegistered
    private let service = SMAppService.agent(plistName: plistName)

    init() { refresh() }

    func refresh() { status = service.status }

    func enable() throws {
        try service.register()
        refresh()
    }

    func disable() throws {
        try service.unregister()
        refresh()
    }

    /// launchd ties a registered agent to the signature of the build that was registered. These builds are ad-hoc
    /// signed, so each rebuild has a new signature and launchd refuses to start it ("Launch Constraint Violation").
    /// Registering again after an update refreshes that. A Developer ID signature would make this unnecessary.
    static func reRegisterIfUpdated() {
        let service = SMAppService.agent(plistName: plistName)
        guard service.status == .enabled,
              let data = try? Data(contentsOf: Bundle.main.bundleURL.appendingPathComponent(
                  "Contents/Library/LoginItems/FocusBlockerAgent.app/Contents/MacOS/focus-agent")) else { return }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard UserDefaults.standard.string(forKey: hashKey) != hash else { return }
        reRegister(hash: hash, attempt: 1)
    }

    static let hashKey = "registeredAgentHash"

    /// Registering too soon after an update, or before the unregister has finished, can leave launchd without the
    /// new signature, and the agent then never starts. So: wait for the unregister, let the system settle, register,
    /// confirm the agent is really running, and retry once if it isn't. Success is only recorded once it runs.
    static func reRegister(hash: String, attempt: Int) {
        SMAppService.agent(plistName: plistName).unregister { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                // A fresh handle each time: SMAppService isn't Sendable, so don't carry one across queues.
                do {
                    try SMAppService.agent(plistName: plistName).register()
                } catch {
                    NSLog("FocusBlocker: re-registering the agent failed: %@", error.localizedDescription)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.focusblocker.agent").isEmpty {
                        UserDefaults.standard.set(hash, forKey: hashKey)
                        NSLog("FocusBlocker: updated agent re-registered and running (attempt %ld)", attempt)
                    } else if attempt < 2 {
                        NSLog("FocusBlocker: agent didn't start after re-registering; retrying")
                        reRegister(hash: hash, attempt: attempt + 1)
                    } else {
                        NSLog("FocusBlocker: agent still not running after re-registering; it will be retried next launch")
                    }
                }
            }
        }
    }

    var statusText: String {
        switch status {
        case .enabled: return "Running in the background"
        case .requiresApproval: return "Waiting for approval in System Settings › General › Login Items"
        case .notRegistered: return "Not enabled"
        case .notFound: return "Not found in this copy of the app. Run Focus Blocker from /Applications."
        @unknown default: return "Unknown"
        }
    }
}

struct ProtectionView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var agent = AgentController()
    @LocalState private var confirmDisable = false

    var body: some View {
        Form {
            Section("Background agent") {
                StatusRow(ok: agent.status == .enabled, title: "Focus agent", detail: agent.statusText)
                Text("While a session is active, the agent closes blocked apps and, in strict sessions, closes Chrome if the Focus extension stops responding. It asks apps to quit normally and never force-quits, so unsaved work isn't lost; an app that stays open is hidden and asked again.")
                    .foregroundStyle(.secondary)
                HStack {
                    if agent.status == .enabled || agent.status == .requiresApproval {
                        Button("Turn off agent") { confirmDisable = true }
                            .disabled(model.activeSessions.contains(where: \.strict))
                        if model.activeSessions.contains(where: \.strict) {
                            Text("Not during a strict session.").foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Turn on agent") { run { try agent.enable() } }
                    }
                    if agent.status == .requiresApproval {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }
            Section("Other browsers") {
                Toggle("Close other browsers during strict sessions that block websites", isOn: Binding(
                    get: { model.state.settings.closeOtherBrowsers },
                    set: { value in model.perform { try $0.setCloseOtherBrowsers(value) } }))
                    .disabled(model.state.settings.closeOtherBrowsers && model.activeSessions.contains(where: \.strict))
                Text("Safari, Arc, Firefox, Brave, Edge and other browsers can't run the Focus extension, so they would get around your website blocks. Chrome stays allowed because the extension filters it. This can't be turned off during a strict session.")
                    .foregroundStyle(.secondary)
            }
            Section("Blocked apps right now") {
                if model.policy.blockedApps.isEmpty {
                    Text(model.isActive ? "This session doesn't block any apps." : "No session is active.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.policy.blockedApps, id: \.bundleID) { Text($0.bundleID) }
            }
            Section("Limits on an admin account") {
                Text("The agent can be turned off in Login Items or stopped from Terminal. Every block it applies is recorded in Activity.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { agent.refresh() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in agent.refresh() }
        .confirmationDialog("Turn off the background agent?", isPresented: $confirmDisable) {
            Button("Turn off", role: .destructive) { run { try agent.disable() } }
        } message: {
            Text("Blocked apps won't be closed until you turn it back on.")
        }
    }

    func run(_ action: () throws -> Void) {
        do {
            try action()
            model.errorMessage = nil
        } catch {
            model.errorMessage = "Background agent: \(error.localizedDescription)"
        }
    }
}
