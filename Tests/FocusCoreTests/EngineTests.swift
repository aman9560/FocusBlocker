import Foundation
@testable import FocusCore

let engineTests: [(String, () throws -> Void)] = [
    ("a session completes after its credited duration, not its wall-clock end", {
        let fx = Fixture()
        let engine = try fx.engine()
        try engine.createBlocklist(name: "Social", domains: ["reddit.com"])
        let session = try engine.startSession(blocklistNames: ["social"], duration: 600, lock: .none, strict: true)
        try expect(engine.policy().blockedDomains == ["reddit.com"])

        fx.clock.advance(300)
        fx.clock.wall += 3600  // Someone moves the clock forward an hour.
        try engine.tick()
        try expect(engine.state.activeSessions.first?.remaining == 300)

        fx.clock.advance(300)
        let events = try engine.tick()
        try expect(engine.state.activeSessions.isEmpty)
        try expect(events.contains { if case .sessionEnded(let s) = $0 { return s.id == session.id && s.endReason == .completed }; return false })
        try expect(engine.policy() == .inactive)
    }),

    ("sessions survive an app restart and a reboot", {
        let fx = Fixture()
        do {
            let engine = try fx.engine()
            try engine.createBlocklist(name: "Social", domains: ["x.com"])
            try engine.startSession(blocklistNames: ["Social"], duration: 3600, lock: .timer, strict: true)
            fx.clock.advance(600)
            try engine.tick()
        }
        // App killed and relaunched in the same boot.
        fx.clock.advance(100)
        let relaunched = try fx.engine()
        try relaunched.tick()
        try expect(relaunched.state.activeSessions.first?.remaining == 2900)

        // Mac off for 10 minutes, then rebooted.
        fx.clock.reboot(offlineFor: 600)
        let rebooted = try fx.engine()
        try rebooted.tick()
        try expect(rebooted.state.activeSessions.first?.remaining == 2300)
        try expect(rebooted.policy().blockedDomains == ["x.com"])
    }),

    ("timer-locked sessions can't be stopped", {
        let fx = Fixture()
        let engine = try fx.engine()
        try engine.createBlocklist(name: "L", domains: ["a.com"])
        try engine.startSession(blocklistNames: ["L"], duration: 120, lock: .timer, strict: true)
        try expectThrows(.timerLocked(remaining: 120)) { try engine.stopSessions(password: "anything") }
        try expect(engine.state.activeSessions.count == 1)
        try expect(try fx.audit.entries().contains { $0.event == "unlock.refused" })
    }),

    ("password-locked sessions need the accountability password, with lockout", {
        let fx = Fixture()
        let engine = try fx.engine()
        try engine.createBlocklist(name: "L", domains: ["a.com"])
        try expectThrows(.noAccountabilityPassword) {
            try engine.startSession(blocklistNames: ["L"], duration: 600, lock: .password, strict: true)
        }
        try engine.setAccountabilityPassword("partner-secret", current: nil)
        try engine.startSession(blocklistNames: ["L"], duration: 600, lock: .password, strict: true)

        for _ in 0..<3 { try expectThrows(.wrongPassword) { try engine.stopSessions(password: "guess") } }
        try expectThrows(.lockedOut(remaining: 30)) { try engine.stopSessions(password: "partner-secret") }
        try expect(engine.state.activeSessions.count == 1)

        // The lockout survives a restart.
        fx.clock.advance(10)
        let restarted = try fx.engine()
        try expectThrows(.lockedOut(remaining: 20)) { try restarted.stopSessions(password: "partner-secret") }

        fx.clock.advance(20)
        let ended = try restarted.stopSessions(password: "partner-secret")
        try expect(ended.count == 1 && ended[0].endReason == .unlockedWithPassword)
        try expect(restarted.state.limiter == AttemptLimiter())
    }),

    ("strict sessions only allow edits that block more", {
        let fx = Fixture()
        let engine = try fx.engine()
        try engine.setAccountabilityPassword("partner-secret", current: nil)
        var list = try engine.createBlocklist(name: "Social", domains: ["reddit.com"], exceptions: ["reddit.com/r/swift"])
        try engine.startSession(blocklistNames: ["Social"], duration: 600, lock: .password, strict: true)

        list.domains.append("YouTube.com")
        try engine.updateBlocklist(list)
        try expect(engine.policy().blockedDomains == ["reddit.com", "youtube.com"], "adding sites is allowed")

        var weaker = try engine.blocklist(named: "Social")
        weaker.domains = ["youtube.com"]
        try expectThrows(.weakensActiveSession("removing blocked websites")) { try engine.updateBlocklist(weaker) }

        var moreExceptions = try engine.blocklist(named: "Social")
        moreExceptions.exceptions.append("reddit.com/r/macos")
        try expectThrows(.weakensActiveSession("adding exceptions")) { try engine.updateBlocklist(moreExceptions) }

        try expectThrows(.weakensActiveSession("deleting a blocklist in use")) { try engine.deleteBlocklist(named: "Social") }
        try expectThrows(.passwordChangeBlockedDuringSession) { try engine.setAccountabilityPassword("new-secret-1", current: "partner-secret") }
    }),

    ("durations are bounded by the hard cap", {
        let fx = Fixture()
        let engine = try fx.engine()
        try engine.createBlocklist(name: "L", domains: ["a.com"])
        let cap = engine.state.settings.maxSessionDuration
        try expectThrows(.invalidDuration(maximum: cap)) { try engine.startSession(blocklistNames: ["L"], duration: cap + 1, lock: .none, strict: false) }
        try expectThrows(.invalidDuration(maximum: cap)) { try engine.startSession(blocklistNames: ["L"], duration: 30, lock: .none, strict: false) }
        try expectThrows(.unknownBlocklist("nope")) { try engine.startSession(blocklistNames: ["nope"], duration: 600, lock: .none, strict: false) }
    }),

    ("schedules start one session per occurrence and survive restarts", {
        let fx = Fixture()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        fx.clock.wall = cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 8, minute: 59))!  // Monday
        let engine = try fx.engine()
        let list = try engine.createBlocklist(name: "Work", domains: ["news.com"])
        try engine.upsertSchedule(ScheduleRule(name: "mornings", blocklistIDs: [list.id], weekdays: [2], startMinute: 540,
                                               endMinute: 600, timeZoneID: "UTC", lock: .none, strict: true))
        try expect(engine.state.activeSessions.isEmpty)

        fx.clock.advance(60)
        try engine.tick()
        try expect(engine.state.activeSessions.count == 1)
        try expect(engine.state.activeSessions[0].duration == 3600)

        // Stopping an unlocked scheduled session doesn't immediately restart it within the same occurrence.
        try engine.stopSessions(password: nil)
        fx.clock.advance(60)
        let restarted = try fx.engine()
        try restarted.tick()
        try expect(restarted.state.activeSessions.isEmpty)

        try expectThrows(.duplicateName("Mornings")) {
            try restarted.upsertSchedule(ScheduleRule(name: "Mornings", blocklistIDs: [list.id], weekdays: [3], startMinute: 0, endMinute: 60, timeZoneID: "UTC"))
        }
    }),

    ("schedules can't be weakened or deleted during a strict session", {
        let fx = Fixture()
        let engine = try fx.engine()
        let list = try engine.createBlocklist(name: "Work", domains: ["news.com"])
        let rule = ScheduleRule(name: "evenings", blocklistIDs: [list.id], weekdays: [1, 2, 3], startMinute: 1200, endMinute: 1320, timeZoneID: "UTC")
        try engine.upsertSchedule(rule)
        try engine.startSession(blocklistNames: ["Work"], duration: 600, lock: .timer, strict: true)

        var fewerDays = rule
        fewerDays.weekdays = [1]
        try expectThrows(.weakensActiveSession("weakening a schedule")) { try engine.upsertSchedule(fewerDays) }
        var moreDays = rule
        moreDays.weekdays = [1, 2, 3, 4]
        try engine.upsertSchedule(moreDays)
        try expectThrows(.weakensActiveSession("deleting a schedule")) { try engine.deleteSchedule(named: "evenings") }
    }),

    ("tampered state falls back to the last good copy, then refuses to load", {
        let fx = Fixture()
        do {
            let engine = try fx.engine()
            try engine.createBlocklist(name: "A", domains: ["a.com"])
            try engine.startSession(blocklistNames: ["A"], duration: 600, lock: .timer, strict: true)
        }
        let primary = fx.dir.appendingPathComponent("state.json")
        var text = try String(contentsOf: primary, encoding: .utf8)
        // Flip one character of the base64 payload, as a hand edit would.
        let idx = text.range(of: "\"payload\":\"")!.upperBound
        let next = text.index(after: idx)
        text.replaceSubrange(idx..<next, with: text[idx] == "A" ? "B" : "A")
        try text.write(to: primary, atomically: true, encoding: .utf8)

        let recovered = try fx.engine()
        try expect(recovered.state.blocklists.count == 1, "backup is the state before the session started")
        try expect(try fx.audit.entries().contains { $0.event == "state.recovered" })

        try "{}".write(to: primary, atomically: true, encoding: .utf8)
        try "{}".write(to: fx.dir.appendingPathComponent("state.prev.json"), atomically: true, encoding: .utf8)
        do {
            _ = try fx.engine()
            throw TestFailure(description: "expected stateTampered")
        } catch FocusError.stateTampered {}
    }),

    ("the audit log detects edited or removed entries", {
        let fx = Fixture()
        let log = fx.audit
        for i in 1...3 { try log.append("event.\(i)", "detail \(i)", at: Date(timeIntervalSince1970: Double(i))) }
        try expect(try log.verify() == .intact(count: 3))

        let url = fx.dir.appendingPathComponent("audit.log")
        let original = try String(contentsOf: url, encoding: .utf8)
        try original.replacingOccurrences(of: "detail 2", with: "detail X").write(to: url, atomically: true, encoding: .utf8)
        try expect(try log.verify() == .broken(atLine: 2, reason: "MAC mismatch"))

        var lines = original.split(separator: "\n")
        lines.remove(at: 1)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try expect(try log.verify() == .broken(atLine: 2, reason: "sequence gap"))
    }),

    ("idle ticks don't rewrite the state file, yet time is still credited", {
        let fx = Fixture()
        let engine = try fx.engine()
        try engine.createBlocklist(name: "A", domains: ["a.com"])
        try engine.startSession(blocklistNames: ["A"], duration: 600, lock: .timer, strict: true)
        let file = fx.dir.appendingPathComponent("state.json")
        let saved = try Data(contentsOf: file)

        for _ in 0..<10 {
            fx.clock.advance(1)
            try engine.tick()
        }
        try expect(try Data(contentsOf: file) == saved, "10 idle ticks must not save")
        try expect(engine.state.activeSessions.first?.remaining == 590, "in-memory state shows live time")
        try expect(try fx.engine().state.activeSessions.first?.remaining == 600, "disk still has the older anchor")

        let other = try fx.engine()
        try other.tick()
        try expect(other.state.activeSessions.first?.remaining == 590, "another process credits the same time")

        fx.clock.advance(25)
        try engine.tick()
        try expect(try Data(contentsOf: file) != saved, "saved once 30 s have passed since the saved anchor")
    }),

    ("clock anomalies are audited", {
        let fx = Fixture()
        let engine = try fx.engine()
        try engine.tick()
        fx.clock.wall += 7200
        let events = try engine.tick()
        try expect(events == [.clockAnomaly(.wallJumpedForward(seconds: 7200))])
        try expect(try fx.audit.entries().last?.event == "clock.anomaly")
    }),
]
