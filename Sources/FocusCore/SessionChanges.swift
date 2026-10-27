import Foundation

/// Notices sessions starting and ending between two looks at the state, whichever process caused the change
/// (the app, focusctl, a schedule, or the timer running out).
public struct SessionChangeTracker {
    var known: Set<UUID>?

    public init() {}

    /// The first call only records what is already running, so restarting the agent doesn't re-announce it.
    public mutating func update(_ state: FocusState) -> (started: [Session], ended: [Session]) {
        let active = Set(state.activeSessions.map(\.id))
        defer { known = active }
        guard let known else { return ([], []) }
        let started = state.activeSessions.filter { !known.contains($0.id) }
        let ended = state.sessions.filter { known.contains($0.id) && !$0.isActive }
        return (started, ended)
    }
}

/// Text for the agent's notifications. Kept here so it can be tested and reused by the app.
public enum FocusNotice {
    public struct Content: Equatable {
        public var title: String
        public var body: String
    }

    public static func started(_ session: Session, listNames: String) -> Content {
        let lock: String
        switch session.lock {
        case .timer: lock = "Timer-locked: normal stop is disabled; emergency failsafe is available."
        case .password: lock = "Ending it early needs the accountability password."
        case .none: lock = "You can stop it any time."
        }
        let origin: String
        if case .scheduled = session.origin { origin = "Scheduled session" } else { origin = "Focus session" }
        return Content(title: "\(origin) started", body: "\(listNames) for \(duration(session.duration)). \(lock)")
    }

    public static func ended(_ session: Session, listNames: String) -> Content {
        switch session.endReason {
        case .completed?: return Content(title: "Focus session complete", body: "\(listNames) is unblocked. Nice work.")
        case .unlockedWithPassword?: return Content(title: "Focus session ended early", body: "\(listNames) was unlocked with the accountability password.")
        case .failsafe?: return Content(title: "Focus session ended with failsafe", body: "\(listNames) was ended early. Your blocklists and settings were preserved.")
        default: return Content(title: "Focus session stopped", body: "\(listNames) is unblocked.")
        }
    }

    public static func closed(appName: String, reason: String, until end: Date?) -> Content {
        var body = "\(appName) was closed: \(reason)."
        if let end {
            body += " Blocked until \(end.formatted(date: .omitted, time: .shortened))."
        }
        return Content(title: "\(appName) is blocked", body: body)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
