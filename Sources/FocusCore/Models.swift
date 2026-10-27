import Foundation

/// A named set of websites and apps to block together.
public struct Blocklist: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Normalized rules such as `reddit.com` or `youtube.com/shorts`.
    public var domains: [String]
    /// Rules that stay reachable even though a broader rule in this list blocks them.
    public var exceptions: [String]
    public var apps: [AppRule]

    public init(id: UUID = UUID(), name: String, domains: [String] = [], exceptions: [String] = [], apps: [AppRule] = []) {
        self.id = id
        self.name = name
        self.domains = domains
        self.exceptions = exceptions
        self.apps = apps
    }
}

/// Identifies an app by code-signing identity, so renamed or copied bundles still match.
public struct AppRule: Codable, Hashable, Sendable {
    public var bundleID: String
    /// When set, only binaries signed by this team match.
    public var teamID: String?

    public init(bundleID: String, teamID: String? = nil) {
        self.bundleID = bundleID
        self.teamID = teamID
    }
}

public enum LockKind: String, Codable, Sendable, CaseIterable {
    /// Can be stopped at any time.
    case none
    /// Cannot be stopped early through normal session controls; the emergency failsafe remains available.
    case timer
    /// Can be stopped early only with the accountability password.
    case password
}

public enum SessionOrigin: Codable, Equatable, Sendable {
    case manual
    case scheduled(ruleID: UUID, occurrenceStart: Date)
}

public enum EndReason: String, Codable, Sendable {
    case completed
    case stoppedUnlocked
    case unlockedWithPassword
    case failsafe
}

public struct Session: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var blocklistIDs: [UUID]
    public var origin: SessionOrigin
    public var lock: LockKind
    /// Strict sessions also freeze edits that would weaken the active blocklists.
    public var strict: Bool
    public var startedAt: Date
    /// Total focus time the session must accumulate before it ends.
    public var duration: TimeInterval
    /// Focus time accumulated so far. Advanced by `TimeAccountant`, never by reading the wall clock directly.
    public var credited: TimeInterval
    public var endedAt: Date?
    public var endReason: EndReason?

    public var isActive: Bool { endedAt == nil }
    public var remaining: TimeInterval { max(0, duration - credited) }
}

public struct ScheduleRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var blocklistIDs: [UUID]
    /// `Calendar` weekday numbers: 1 = Sunday … 7 = Saturday.
    public var weekdays: Set<Int>
    /// Minutes after local midnight. `endMinute <= startMinute` means the window runs past midnight.
    public var startMinute: Int
    public var endMinute: Int
    /// Pinned so changing the Mac's time zone does not move the window.
    public var timeZoneID: String
    public var lock: LockKind
    public var strict: Bool
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, blocklistIDs: [UUID], weekdays: Set<Int>, startMinute: Int, endMinute: Int,
                timeZoneID: String = TimeZone.current.identifier, lock: LockKind = .timer, strict: Bool = true, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.blocklistIDs = blocklistIDs
        self.weekdays = weekdays
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.timeZoneID = timeZoneID
        self.lock = lock
        self.strict = strict
        self.enabled = enabled
    }
}

public struct Settings: Codable, Equatable, Sendable {
    /// Upper bound on any single session, so a mistake can never block indefinitely.
    public var maxSessionDuration: TimeInterval = 12 * 3600
    /// Seconds Chrome may run without an extension heartbeat during a strict session.
    public var extensionGracePeriod: TimeInterval = 30
    /// During strict sessions that block websites, close browsers that can't run the Focus extension.
    public var closeOtherBrowsers = true

    public init() {}

    /// Missing keys take their defaults, so state saved by an older version still loads after a setting is added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        maxSessionDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .maxSessionDuration) ?? defaults.maxSessionDuration
        extensionGracePeriod = try c.decodeIfPresent(TimeInterval.self, forKey: .extensionGracePeriod) ?? defaults.extensionGracePeriod
        closeOtherBrowsers = try c.decodeIfPresent(Bool.self, forKey: .closeOtherBrowsers) ?? defaults.closeOtherBrowsers
    }
}

/// Everything the engine persists. Versioned so later increments can migrate it.
public struct FocusState: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var blocklists: [Blocklist] = []
    public var schedules: [ScheduleRule] = []
    public var sessions: [Session] = []
    public var accountability: PasswordRecord?
    public var limiter = AttemptLimiter()
    public var settings = Settings()
    public var clockAnchor: ClockAnchor?
    /// Last occurrence start each schedule rule has already produced a session for.
    public var lastScheduledOccurrence: [UUID: Date] = [:]

    public init() {}

    public var activeSessions: [Session] { sessions.filter(\.isActive) }
}
