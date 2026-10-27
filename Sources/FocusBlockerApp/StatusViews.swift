import FocusCore
import SwiftUI

struct ChromeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Connection") {
                StatusRow(ok: model.hostManifestInstalled, title: "Native messaging host",
                          detail: model.hostManifestInstalled ? "Installed for Google Chrome" : "Not installed. Run focusctl chrome install-host.")
                StatusRow(ok: model.chromeConnected, title: "Extension",
                          detail: heartbeatText)
                if let beat = model.heartbeat {
                    StatusRow(ok: beat.incognitoAllowed, title: "Incognito",
                              detail: beat.incognitoAllowed ? "Allowed: incognito windows are filtered"
                                                            : "Not allowed: turn on Allow in Incognito in chrome://extensions")
                    StatusRow(ok: beat.rulesRevision == model.policy.revision, title: "Rules",
                              detail: "\(beat.ruleCount) rules in Chrome, \(beat.rulesRevision == model.policy.revision ? "up to date" : "updating")")
                }
            }
            Section("Limits") {
                Text("Chrome can still remove the extension or turn off Developer mode. A later step adds an agent that quits Chrome when the extension stops reporting, and a policy profile that locks the extension in place.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    var heartbeatText: String {
        guard let beat = model.heartbeat, let age = model.heartbeatAge else { return "No heartbeat yet. Load the extension in Chrome." }
        let when = age.isFinite ? "\(Int(age)) s ago" : "before the last restart"
        return "v\(beat.extensionVersion), last heartbeat \(when)"
    }
}

struct StatusRow: View {
    let ok: Bool
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).foregroundStyle(.secondary).font(.callout)
            }
        }
    }
}

struct AccountabilityView: View {
    @EnvironmentObject var model: AppModel
    @LocalState private var current = ""
    @LocalState private var new = ""
    @LocalState private var repeated = ""

    var body: some View {
        Form {
            Section {
                Text("The accountability password ends password-locked sessions early. Have someone you trust set it, or write it down and put it away. It is separate from your Mac password and only a salted hash is stored.")
                    .foregroundStyle(.secondary)
                LabeledContent("Status", value: model.state.accountability == nil ? "Not set" : "Set")
                if model.state.limiter.isLockedOut {
                    LabeledContent("Locked after wrong attempts", value: Format.duration(model.state.limiter.lockoutRemaining))
                }
            }
            Section(model.state.accountability == nil ? "Set password" : "Change password") {
                if model.state.accountability != nil {
                    SecureField("Current password", text: $current)
                }
                SecureField("New password (8+ characters)", text: $new)
                SecureField("Repeat new password", text: $repeated)
                Button("Save password", action: save)
                    .disabled(new.count < PasswordHasher.minimumLength || new != repeated)
            }
        }
        .formStyle(.grouped)
    }

    func save() {
        let currentValue = model.state.accountability == nil ? nil : current
        if model.perform("Accountability password saved.", { try $0.setAccountabilityPassword(new, current: currentValue) }) {
            current = ""
            new = ""
            repeated = ""
        }
    }
}

struct ActivityView: View {
    @EnvironmentObject var model: AppModel
    @LocalState private var entries: [AuditEntry] = []
    @LocalState private var verification = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Verify log") {
                    switch (try? model.audit?.verify()) ?? nil {
                    case .intact(let count)?: verification = "Intact: \(count) entries"
                    case .broken(let line, let reason)?: verification = "Broken at line \(line): \(reason)"
                    case nil: verification = "Couldn't read the log"
                    }
                }
                Text(verification).foregroundStyle(verification.hasPrefix("Intact") ? Color.green : Color.red)
                Spacer()
                Button("Reload") { entries = model.auditEntries().reversed() }
            }
            .padding(12)
            Table(entries) {
                TableColumn("Time") { Text($0.time.formatted(date: .abbreviated, time: .standard)) }
                    .width(min: 150, ideal: 170)
                TableColumn("Event", value: \.event).width(min: 120, ideal: 150)
                TableColumn("Detail", value: \.detail)
            }
        }
        .onAppear { entries = model.auditEntries().reversed() }
    }
}
