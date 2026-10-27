import Foundation

public enum EngineEvent: Equatable {
    case sessionStarted(Session)
    case sessionEnded(Session)
    case clockAnomaly(ClockAnomaly)
    case recoveredFromBackup(String)
}

/// The policy authority: owns sessions, schedules, blocklists and the accountability password.
///
/// Several processes share one state folder (focusctl, the native messaging host, later the agent). Every public
/// operation therefore runs as a transaction: take the folder lock, reload from disk, bring time up to date, validate,
/// mutate, save, release. A crash at any point leaves either the old or the new state on disk.
public final class FocusEngine {
    public private(set) var state: FocusState
    let store: StateStore
    let audit: AuditLog
    let clock: ClockSource
    /// Lower in tests; production uses `PasswordHasher.defaultIterations`.
    let passwordIterations: Int

    public init(store: StateStore, audit: AuditLog, clock: ClockSource = SystemClock(),
                passwordIterations: Int = PasswordHasher.defaultIterations) throws {
        self.store = store
        self.audit = audit
        self.clock = clock
        self.passwordIterations = passwordIterations
        state = FocusState()
        try store.withLock { _ = try reload() }
    }

    // MARK: Time

    /// Credits elapsed focus time, ends finished sessions and starts due scheduled sessions. Call about once a second.
    @discardableResult
    public func tick() throws -> [EngineEvent] {
        try transaction { [] }
    }

    // MARK: Sessions

    @discardableResult
    public func startSession(blocklistNames: [String], duration: TimeInterval, lock: LockKind, strict: Bool) throws -> Session {
        var started: Session!
        try transaction {
            let lists = try blocklistNames.map { try blocklist(named: $0) }
            let ids = lists.map(\.id)
            guard !ids.isEmpty else { throw FocusError.unknownBlocklist("") }
            guard duration >= 60, duration <= state.settings.maxSessionDuration else {
                throw FocusError.invalidDuration(maximum: state.settings.maxSessionDuration)
            }
            if lock == .password && state.accountability == nil { throw FocusError.noAccountabilityPassword }

            let now = clock.wallNow()
            started = makeSession(blocklistIDs: ids, duration: duration, lock: lock, strict: strict, origin: .manual, now: now)
            state.sessions.append(started)
            try audit.append("session.started", "\(lists.map(\.name).joined(separator: ",")), \(Int(duration))s, lock \(lock.rawValue), strict \(strict)", at: now)
            return []
        }
        return started
    }

    /// Ends every active session the caller is allowed to end. Timer-locked sessions are never ended early.
    @discardableResult
    public func stopSessions(password: String?) throws -> [Session] {
        var ended: [Session] = []
        try transaction {
            let now = clock.wallNow()
            let active = state.activeSessions
            if let timer = active.first(where: { $0.lock == .timer }) {
                try audit.append("unlock.refused", "timer lock \(timer.id.uuidString)", at: now)
                throw FocusError.timerLocked(remaining: timer.remaining)
            }

            if active.contains(where: { $0.lock == .password }) {
                guard let record = state.accountability else { throw FocusError.noAccountabilityPassword }
                if state.limiter.isLockedOut {
                    try audit.append("unlock.refused", "locked out", at: now)
                    throw FocusError.lockedOut(remaining: state.limiter.lockoutRemaining)
                }
                guard let password, PasswordHasher.verify(password, against: record) else {
                    state.limiter.recordFailure()
                    try audit.append("unlock.failed", "failures \(state.limiter.failures)", at: now)
                    throw FocusError.wrongPassword
                }
                state.limiter.recordSuccess()
            }

            for index in state.sessions.indices where state.sessions[index].isActive {
                state.sessions[index].endedAt = now
                state.sessions[index].endReason = state.sessions[index].lock == .password ? .unlockedWithPassword : .stoppedUnlocked
                ended.append(state.sessions[index])
                let s = state.sessions[index]
                try audit.append("session.stopped", "\(s.id.uuidString) \(s.endReason!.rawValue), \(Int(s.remaining))s left", at: now)
            }
            return []
        }
        return ended
    }

    /// Ends all active sessions immediately while preserving blocklists, schedules and settings.
    /// This explicit emergency escape hatch is recorded in the activity log.
    @discardableResult
    public func endSessionsWithFailsafe() throws -> [Session] {
        var ended: [Session] = []
        try transaction {
            let now = clock.wallNow()
            for index in state.sessions.indices where state.sessions[index].isActive {
                state.sessions[index].endedAt = now
                state.sessions[index].endReason = .failsafe
                ended.append(state.sessions[index])
            }
            guard !ended.isEmpty else { return [] }
            try audit.append("session.failsafe_ended", "Ended \(ended.count) active session(s); configuration preserved", at: now)
            return []
        }
        return ended
    }

    /// The policy as of the last transaction. Call `tick()` first for an up-to-date answer.
    public func policy() -> EnforcementPolicy {
        EnforcementPolicy.build(sessions: state.activeSessions, blocklists: state.blocklists, now: clock.wallNow())
    }

    // MARK: Accountability password

    public func setAccountabilityPassword(_ new: String, current: String?) throws {
        try transaction {
            if state.activeSessions.contains(where: \.strict) { throw FocusError.passwordChangeBlockedDuringSession }
            let isChange = state.accountability != nil
            if let record = state.accountability {
                guard !state.limiter.isLockedOut else { throw FocusError.lockedOut(remaining: state.limiter.lockoutRemaining) }
                guard let current, PasswordHasher.verify(current, against: record) else {
                    state.limiter.recordFailure()
                    try audit.append("password.change.failed", "", at: clock.wallNow())
                    throw FocusError.wrongPassword
                }
            }
            state.accountability = try PasswordHasher.makeRecord(password: new, iterations: passwordIterations)
            state.limiter.recordSuccess()
            try audit.append(isChange ? "password.changed" : "password.set", "", at: clock.wallNow())
            return []
        }
    }

    // MARK: Blocklists

    public func blocklist(named name: String) throws -> Blocklist {
        guard let list = state.blocklists.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw FocusError.unknownBlocklist(name)
        }
        return list
    }

    @discardableResult
    public func createBlocklist(name: String, domains: [String] = [], exceptions: [String] = [], apps: [AppRule] = []) throws -> Blocklist {
        var created: Blocklist!
        try transaction {
            guard (try? blocklist(named: name)) == nil else { throw FocusError.duplicateName(name) }
            try validateApps(apps)
            created = Blocklist(name: name, domains: try DomainRule.normalize(domains),
                                exceptions: try DomainRule.normalize(exceptions), apps: apps)
            state.blocklists.append(created)
            try audit.append("blocklist.created", name, at: clock.wallNow())
            return []
        }
        return created
    }

    /// Replaces a blocklist. While a strict session uses it, the new version may only block more.
    public func updateBlocklist(_ updated: Blocklist) throws {
        try transaction {
            guard let index = state.blocklists.firstIndex(where: { $0.id == updated.id }) else { throw FocusError.unknownBlocklist(updated.name) }
            var normalized = updated
            normalized.domains = try DomainRule.normalize(updated.domains)
            normalized.exceptions = try DomainRule.normalize(updated.exceptions)
            try validateApps(normalized.apps)
            let old = state.blocklists[index]

            if isLockedByStrictSession(old.id) {
                if !Set(normalized.domains).isSuperset(of: old.domains) { throw FocusError.weakensActiveSession("removing blocked websites") }
                if !Set(normalized.apps).isSuperset(of: old.apps) { throw FocusError.weakensActiveSession("removing blocked apps") }
                if !Set(normalized.exceptions).isSubset(of: old.exceptions) { throw FocusError.weakensActiveSession("adding exceptions") }
                if normalized.name != old.name { throw FocusError.weakensActiveSession("renaming an active blocklist") }
            }
            state.blocklists[index] = normalized
            try audit.append("blocklist.updated", normalized.name, at: clock.wallNow())
            return []
        }
    }

    public func deleteBlocklist(named name: String) throws {
        try transaction {
            let list = try blocklist(named: name)
            if state.activeSessions.contains(where: { $0.blocklistIDs.contains(list.id) }) {
                throw FocusError.weakensActiveSession("deleting a blocklist in use")
            }
            if state.schedules.contains(where: { $0.blocklistIDs.contains(list.id) }) {
                throw FocusError.weakensActiveSession("deleting a blocklist a schedule uses; delete the schedule first")
            }
            state.blocklists.removeAll { $0.id == list.id }
            try audit.append("blocklist.deleted", name, at: clock.wallNow())
            return []
        }
    }

    // MARK: Schedules

    public func upsertSchedule(_ rule: ScheduleRule) throws {
        try transaction {
            try rule.validate()
            for id in rule.blocklistIDs where !state.blocklists.contains(where: { $0.id == id }) {
                throw FocusError.unknownBlocklist(id.uuidString)
            }
            if rule.lock == .password && state.accountability == nil { throw FocusError.noAccountabilityPassword }
            if let index = state.schedules.firstIndex(where: { $0.id == rule.id }) {
                if anyStrictSessionActive && !rule.isNoWeakerThan(state.schedules[index]) {
                    throw FocusError.weakensActiveSession("weakening a schedule")
                }
                state.schedules[index] = rule
            } else {
                guard !state.schedules.contains(where: { $0.name.caseInsensitiveCompare(rule.name) == .orderedSame }) else {
                    throw FocusError.duplicateName(rule.name)
                }
                state.schedules.append(rule)
            }
            try audit.append("schedule.saved", rule.name, at: clock.wallNow())
            // Start the schedule right away if its window is already open.
            return try startDueSchedules(at: clock.wallNow())
        }
    }

    public func deleteSchedule(named name: String) throws {
        try transaction {
            guard let rule = state.schedules.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw FocusError.unknownSchedule(name)
            }
            if anyStrictSessionActive && rule.enabled { throw FocusError.weakensActiveSession("deleting a schedule") }
            state.schedules.removeAll { $0.id == rule.id }
            state.lastScheduledOccurrence[rule.id] = nil
            try audit.append("schedule.deleted", name, at: clock.wallNow())
            return []
        }
    }

    // MARK: Settings

    /// Turning the browser rule off would weaken a strict session, so that is refused while one runs.
    public func setCloseOtherBrowsers(_ enabled: Bool) throws {
        try transaction {
            if !enabled && anyStrictSessionActive {
                throw FocusError.weakensActiveSession("turning off closing other browsers")
            }
            guard state.settings.closeOtherBrowsers != enabled else { return [] }
            state.settings.closeOtherBrowsers = enabled
            try audit.append("settings.changed", "closeOtherBrowsers \(enabled)", at: clock.wallNow())
            return []
        }
    }

    // MARK: Transactions

    /// Locks the state folder, reloads, advances time, runs `body`, then saves.
    ///
    /// State is saved even when `body` throws: bodies validate before mutating, and the only changes made before a
    /// throw are deliberate ones such as elapsed time and a recorded password failure.
    @discardableResult
    func transaction(_ body: () throws -> [EngineEvent]) throws -> [EngineEvent] {
        try store.withLock {
            var events = try reload()
            let loaded = state
            events += try advanceTime()
            do {
                events += try body()
            } catch {
                try store.save(state)
                throw error
            }
            pruneHistory()
            // When only elapsed time changed, the in-memory state keeps the advanced counters for display, and the
            // next transaction reloads from disk and credits the same time again from the saved anchor.
            if !events.isEmpty || needsSave(comparedTo: loaded) {
                try store.save(state)
            }
            return events
        }
    }

    /// Saving only elapsed-time counters every second would rewrite and fsync the state file constantly. Those
    /// counters are always recomputed from the saved clock anchor, so skipping the save loses nothing. Still save at
    /// least every 30 s, which bounds how much time is credited by wall clock after a reboot.
    func needsSave(comparedTo loaded: FocusState) -> Bool {
        if loaded.clockAnchor == nil { return true }
        if let old = loaded.clockAnchor, let new = state.clockAnchor,
           old.bootID != new.bootID || new.monotonic - old.monotonic >= 30 { return true }
        func stable(_ s: FocusState) -> FocusState {
            var copy = s
            copy.clockAnchor = nil
            copy.limiter.lockoutRemaining = copy.limiter.lockoutRemaining > 0 ? 1 : 0
            for i in copy.sessions.indices { copy.sessions[i].credited = 0 }
            return copy
        }
        return stable(loaded) != stable(state)
    }

    /// Must be called with the folder lock held.
    @discardableResult
    func reload() throws -> [EngineEvent] {
        let (loaded, outcome) = try store.load()
        state = loaded
        if case .recoveredFromBackup(let reason) = outcome {
            try audit.append("state.recovered", reason, at: clock.wallNow())
            return [.recoveredFromBackup(reason)]
        }
        return []
    }

    func advanceTime() throws -> [EngineEvent] {
        let (elapsed, anomaly, anchor) = TimeAccountant.advance(from: state.clockAnchor, clock: clock)
        state.clockAnchor = anchor
        let now = anchor.wall
        var events: [EngineEvent] = []

        if let anomaly {
            events.append(.clockAnomaly(anomaly))
            try audit.append("clock.anomaly", String(describing: anomaly), at: now)
        }

        state.limiter.elapse(elapsed)
        for index in state.sessions.indices where state.sessions[index].isActive {
            state.sessions[index].credited += elapsed
            if state.sessions[index].remaining <= 0 {
                state.sessions[index].endedAt = now
                state.sessions[index].endReason = .completed
                events.append(.sessionEnded(state.sessions[index]))
                try audit.append("session.completed", state.sessions[index].id.uuidString, at: now)
            }
        }
        return events + (try startDueSchedules(at: now))
    }

    func startDueSchedules(at now: Date) throws -> [EngineEvent] {
        var events: [EngineEvent] = []
        for rule in state.schedules {
            guard let window = rule.activeWindow(at: now), state.lastScheduledOccurrence[rule.id] != window.start else { continue }
            state.lastScheduledOccurrence[rule.id] = window.start
            let duration = min(window.end.timeIntervalSince(now), state.settings.maxSessionDuration)
            guard duration >= 1 else { continue }
            let session = makeSession(blocklistIDs: rule.blocklistIDs, duration: duration, lock: rule.lock, strict: rule.strict,
                                      origin: .scheduled(ruleID: rule.id, occurrenceStart: window.start), now: now)
            state.sessions.append(session)
            events.append(.sessionStarted(session))
            try audit.append("session.started", "schedule \(rule.name), \(Int(duration))s, lock \(rule.lock.rawValue)", at: now)
        }
        return events
    }

    // MARK: Helpers

    func validateApps(_ apps: [AppRule]) throws {
        if let app = apps.first(where: { AppGuard.isProtected($0.bundleID) }) { throw FocusError.protectedApp(app.bundleID) }
    }

    var anyStrictSessionActive: Bool { state.activeSessions.contains(where: \.strict) }

    func isLockedByStrictSession(_ blocklistID: UUID) -> Bool {
        state.activeSessions.contains { $0.strict && $0.blocklistIDs.contains(blocklistID) }
    }

    func makeSession(blocklistIDs: [UUID], duration: TimeInterval, lock: LockKind, strict: Bool, origin: SessionOrigin, now: Date) -> Session {
        Session(id: UUID(), blocklistIDs: blocklistIDs, origin: origin, lock: lock, strict: strict,
                startedAt: now, duration: duration, credited: 0, endedAt: nil, endReason: nil)
    }

    /// Keeps the state file small: all active sessions plus the 200 most recent finished ones.
    func pruneHistory() {
        let finished = state.sessions.filter { !$0.isActive }
        guard finished.count > 200 else { return }
        let keep = Set(finished.suffix(200).map(\.id))
        state.sessions.removeAll { !$0.isActive && !keep.contains($0.id) }
    }
}
