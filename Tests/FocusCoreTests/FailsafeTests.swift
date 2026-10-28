import Foundation
@testable import FocusCore

let failsafeTests: [(String, () throws -> Void)] = [
    ("the failsafe ends timer- and password-locked sessions but keeps all configuration", {
        let fx = Fixture()
        let engine = try fx.engine()
        try engine.setAccountabilityPassword("partner-secret", current: nil)
        try engine.createBlocklist(name: "Web", domains: ["x.com"], exceptions: ["x.com/ok"], apps: [AppRule(bundleID: "com.example.app")])
        try engine.createBlocklist(name: "Other", domains: ["y.com"])
        try engine.startSession(blocklistNames: ["Web"], duration: 3600, lock: .timer, strict: true)
        try engine.startSession(blocklistNames: ["Other"], duration: 3600, lock: .password, strict: true)
        try expectThrows(.timerLocked(remaining: 3600)) { try engine.stopSessions(password: "partner-secret") }

        let before = engine.state
        let ended = try engine.endSessionsWithFailsafe()
        try expect(ended.count == 2 && ended.allSatisfy { $0.endReason == .failsafe })
        try expect(engine.state.activeSessions.isEmpty && engine.policy() == .inactive)
        try expect(engine.state.blocklists == before.blocklists, "blocklists untouched")
        try expect(engine.state.accountability == before.accountability, "password untouched")
        try expect(engine.state.settings == before.settings && engine.state.schedules == before.schedules)

        let entry = try fx.audit.entries().last
        try expect(entry?.event == "session.failsafe_ended", "recorded in the audit log")
        try expect(try fx.audit.verify() == .intact(count: try fx.audit.entries().count))
        try expect(try fx.engine().state.activeSessions.isEmpty, "stays ended after a restart")
    }),

    ("the failsafe with nothing running changes nothing and logs nothing", {
        let fx = Fixture()
        let engine = try fx.engine()
        try engine.createBlocklist(name: "A", domains: ["a.com"])
        let count = try fx.audit.entries().count
        try expect(try engine.endSessionsWithFailsafe().isEmpty)
        try expect(try fx.audit.entries().count == count)
    }),

    ("a scheduled session doesn't restart within the same window after the failsafe", {
        let fx = Fixture()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        fx.clock.wall = cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9, minute: 5))!  // Monday
        let engine = try fx.engine()
        let list = try engine.createBlocklist(name: "Work", domains: ["news.com"])
        try engine.upsertSchedule(ScheduleRule(name: "mornings", blocklistIDs: [list.id], weekdays: [2], startMinute: 540,
                                               endMinute: 660, timeZoneID: "UTC", lock: .timer, strict: true))
        try expect(engine.state.activeSessions.count == 1, "window already open, so it started")
        try engine.endSessionsWithFailsafe()
        fx.clock.advance(60)
        try engine.tick()
        try expect(engine.state.activeSessions.isEmpty)

        // The next Monday's window starts a new session.
        fx.clock.advance(7 * 86400)
        try engine.tick()
        try expect(engine.state.activeSessions.count == 1)
    }),
]
