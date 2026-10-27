import FocusCore
import SwiftUI

struct SessionView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.isActive {
                    ActiveSessionsView()
                    Divider()
                    Text("Start another session").font(.headline)
                }
                StartSessionForm()
            }
            .padding(20)
        }
    }
}

struct ActiveSessionsView: View {
    @EnvironmentObject var model: AppModel
    @LocalState private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(model.activeSessions) { session in
                VStack(alignment: .leading, spacing: 6) {
                    Text(Format.duration(session.remaining))
                        .font(.system(size: 48, weight: .semibold, design: .rounded).monospacedDigit())
                    Text(model.names(for: session.blocklistIDs)).font(.title3)
                    HStack(spacing: 8) {
                        Tag(text: lockText(session.lock), symbol: session.lock == .none ? "lock.open" : "lock.fill")
                        if session.strict { Tag(text: "Strict", symbol: "shield.fill") }
                        if case .scheduled = session.origin { Tag(text: "Scheduled", symbol: "calendar") }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.08)))
            }
            stopControls
        }
    }

    @ViewBuilder var stopControls: some View {
        let sessions = model.activeSessions
        if sessions.contains(where: { $0.lock == .timer }) {
            Label("Timer-locked: this can't be stopped early.", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        } else if sessions.contains(where: { $0.lock == .password }) {
            HStack {
                SecureField("Accountability password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .onSubmit(stop)
                Button("End early", action: stop).disabled(password.isEmpty)
            }
            if model.state.limiter.isLockedOut {
                Text("Too many wrong attempts. Try again in \(Format.duration(model.state.limiter.lockoutRemaining)).")
                    .foregroundStyle(.red)
            }
        } else {
            Button("Stop session", action: stop)
        }
    }

    func stop() {
        let entered = password
        password = ""
        model.perform("Session ended.") { try $0.stopSessions(password: entered.isEmpty ? nil : entered) }
    }

    func lockText(_ lock: LockKind) -> String {
        switch lock {
        case .timer: return "Timer lock"
        case .password: return "Password lock"
        case .none: return "No lock"
        }
    }
}

struct StartSessionForm: View {
    @EnvironmentObject var model: AppModel
    @LocalState private var selected: Set<UUID> = []
    @LocalState private var minutes = 25
    @LocalState private var lock: LockKind = .timer
    @LocalState private var strict = true
    @LocalState private var confirmTimer = false

    let presets = [15, 25, 45, 60, 90, 120]

    var body: some View {
        Form {
            if model.state.blocklists.isEmpty {
                Text("Create a blocklist first, in Blocklists.").foregroundStyle(.secondary)
            } else {
                LabeledContent("Blocklists") {
                    VStack(alignment: .leading) {
                        ForEach(model.sortedBlocklists) { list in
                            Toggle(isOn: binding(for: list.id)) {
                                Text(list.name)
                                Text(summary(list)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            LabeledContent("Duration") {
                HStack {
                    Stepper(value: $minutes, in: 1...Int(model.state.settings.maxSessionDuration / 60), step: 5) {
                        Text("\(minutes) min").monospacedDigit().frame(width: 70, alignment: .leading)
                    }
                    ForEach(presets, id: \.self) { p in
                        Button("\(p)") { minutes = p }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            Picker("Lock", selection: $lock) {
                Text("Timer: can't be stopped").tag(LockKind.timer)
                Text("Password: accountability password ends it").tag(LockKind.password)
                Text("None: stop any time").tag(LockKind.none)
            }
            .pickerStyle(.radioGroup)
            Toggle("Strict: block edits that would weaken this session", isOn: $strict)
            if !model.agentEnabled && model.state.blocklists.contains(where: { selected.contains($0.id) && !$0.apps.isEmpty }) {
                Label("These blocklists include apps, but the background agent is off, so the apps won't be closed.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Button("Start focus session") {
                if lock == .timer { confirmTimer = true } else { start() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selected.isEmpty)
        }
        .formStyle(.grouped)
        .confirmationDialog("Start a \(minutes)-minute timer-locked session?", isPresented: $confirmTimer) {
            Button("Start", action: start)
        } message: {
            Text("It can't be stopped from Focus Blocker until the time is up, including after a restart.")
        }
    }

    func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { selected.contains(id) },
                set: { if $0 { selected.insert(id) } else { selected.remove(id) } })
    }

    func summary(_ list: Blocklist) -> String {
        var parts: [String] = []
        if !list.domains.isEmpty { parts.append("\(list.domains.count) site\(list.domains.count == 1 ? "" : "s")") }
        if !list.apps.isEmpty { parts.append("\(list.apps.count) app\(list.apps.count == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    func start() {
        let names = model.state.blocklists.filter { selected.contains($0.id) }.map(\.name)
        model.perform("Session started.") {
            try $0.startSession(blocklistNames: names, duration: TimeInterval(minutes * 60), lock: lock, strict: strict)
        }
    }
}

struct Tag: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}
