import Foundation
@testable import FocusCore

let ruleTests: [(String, () throws -> Void)] = [
    ("domain rules normalize loose input", {
        try expect(try DomainRule(parsing: "https://www.Reddit.com/r/all/?x=1#top").description == "reddit.com/r/all")
        try expect(try DomainRule(parsing: "*.example.org").description == "example.org")
        try expect(try DomainRule(parsing: "news.ycombinator.com:443/").description == "news.ycombinator.com")
        try expect(try DomainRule(parsing: "YouTube.com/Shorts").description == "youtube.com/shorts")
        for bad in ["", "localhost", "exa mple.com", "..com", "a.com/x*y"] {
            try expectThrows(.invalidRule(bad)) { _ = try DomainRule(parsing: bad) }
        }
        try expect(try DomainRule.normalize(["www.x.com", "x.com", "https://x.com/"]) == ["x.com"])
    }),

    ("domain rules match subdomains and path segments only", {
        let host = try DomainRule(parsing: "reddit.com")
        try expect(host.matches(host: "old.reddit.com", path: "/"))
        try expect(host.matches(host: "reddit.com.", path: "/r/swift"))
        try expect(!host.matches(host: "notreddit.com", path: "/"))

        let path = try DomainRule(parsing: "youtube.com/shorts")
        try expect(path.matches(host: "m.youtube.com", path: "/shorts/abc"))
        try expect(path.matches(host: "youtube.com", path: "/shorts"))
        try expect(!path.matches(host: "youtube.com", path: "/shortstack"))
        try expect(!path.matches(host: "youtube.com", path: "/watch"))

        try expect(path.isCovered(by: host) == false)
        try expect(path.isCovered(by: try DomainRule(parsing: "youtube.com")))
        try expect(!(try DomainRule(parsing: "youtube.com")).isCovered(by: path))
    }),

    ("an exception never unblocks a site another list blocks", {
        let a = Blocklist(name: "A", domains: ["reddit.com"], exceptions: ["reddit.com/r/swift"])
        let b = Blocklist(name: "B", domains: ["reddit.com"])
        let c = Blocklist(name: "C", domains: ["youtube.com"])
        func session(_ lists: [Blocklist]) -> Session {
            Session(id: UUID(), blocklistIDs: lists.map(\.id), origin: .manual, lock: .none, strict: false,
                    startedAt: Date(), duration: 600, credited: 0, endedAt: nil, endReason: nil)
        }
        let all = [a, b, c]
        let onlyA = EnforcementPolicy.build(sessions: [session([a, c])], blocklists: all, now: Date())
        try expect(onlyA.exceptions == ["reddit.com/r/swift"])
        try expect(onlyA.blockedDomains == ["reddit.com", "youtube.com"])

        let aAndB = EnforcementPolicy.build(sessions: [session([a]), session([b])], blocklists: all, now: Date())
        try expect(aAndB.exceptions.isEmpty, "B blocks reddit.com without excepting /r/swift")
        try expect(aAndB.revision != onlyA.revision)
        try expect(EnforcementPolicy.build(sessions: [], blocklists: all, now: Date()) == .inactive)
    }),

    ("chrome rules redirect main frames, block subresources and let exceptions win", {
        let list = Blocklist(name: "A", domains: ["reddit.com", "youtube.com/shorts"], exceptions: ["reddit.com/r/swift"])
        let s = Session(id: UUID(), blocklistIDs: [list.id], origin: .manual, lock: .none, strict: true,
                        startedAt: Date(), duration: 600, credited: 0, endedAt: nil, endReason: nil)
        let rules = ChromeRuleCompiler.dnrRules(for: EnforcementPolicy.build(sessions: [s], blocklists: [list], now: Date()))
        try expect(rules.count == 5, "2 per blocked rule + 1 exception, got \(rules.count)")
        try expect(Set(rules.compactMap { $0["id"] as? Int }) == Set(1...5))

        let redirect = rules[0]
        try expect((redirect["action"] as? [String: Any])?["type"] as? String == "redirect")
        try expect((redirect["condition"] as? [String: Any])?["requestDomains"] as? [String] == ["reddit.com"])

        let shorts = rules.first { (($0["condition"] as? [String: Any])?["urlFilter"] as? String) == "||youtube.com/shorts^" }
        try expect(shorts != nil)

        let allow = rules.last!
        try expect((allow["action"] as? [String: Any])?["type"] as? String == "allow")
        try expect(allow["priority"] as? Int == 2)
        try expect(ChromeRuleCompiler.dnrRules(for: .inactive).isEmpty)
        _ = try ChromeRuleCompiler.json(for: .inactive)
    }),

    ("schedule windows respect weekdays, overnight spans and the pinned time zone", {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        // Monday 2026-10-26 10:00 IST.
        let monday10 = cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 10))!
        let work = ScheduleRule(name: "work", blocklistIDs: [UUID()], weekdays: [2, 3, 4, 5, 6],
                                startMinute: 9 * 60, endMinute: 17 * 60, timeZoneID: "Asia/Kolkata")
        let window = work.activeWindow(at: monday10)
        try expect(window?.duration == 8 * 3600)
        try expect(work.activeWindow(at: monday10.addingTimeInterval(8 * 3600)) == nil)
        try expect(work.activeWindow(at: monday10.addingTimeInterval(-2 * 86400)) == nil, "Saturday")

        let night = ScheduleRule(name: "night", blocklistIDs: [UUID()], weekdays: [2], startMinute: 23 * 60, endMinute: 6 * 60,
                                 timeZoneID: "Asia/Kolkata")
        let tuesday2am = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 2))!
        try expect(night.activeWindow(at: tuesday2am)?.duration == 7 * 3600, "Monday's window spans into Tuesday")
        try expect(try Weekday.parse("mon,Wednesday") == [2, 4])
        try expect(try Weekday.parseTime("09:30") == 570)
        try expectThrows(.invalidSchedule("time \"25:00\" must be HH:MM")) { _ = try Weekday.parseTime("25:00") }
    }),

    ("clock changes within a boot don't change credited time", {
        let clock = TestClock()
        var (_, anomaly, anchor) = TimeAccountant.advance(from: nil, clock: clock)
        clock.advance(60)
        clock.wall += 3600
        var elapsed: TimeInterval
        (elapsed, anomaly, anchor) = TimeAccountant.advance(from: anchor, clock: clock)
        try expect(elapsed == 60)
        try expect(anomaly == .wallJumpedForward(seconds: 3600))

        clock.advance(10)
        clock.wall -= 7200
        (elapsed, anomaly, anchor) = TimeAccountant.advance(from: anchor, clock: clock)
        try expect(elapsed == 10)
        try expect(anomaly == .wallJumpedBackward(seconds: 7200))

        clock.reboot(offlineFor: 120)
        (elapsed, anomaly, anchor) = TimeAccountant.advance(from: anchor, clock: clock)
        try expect(elapsed == 120 && anomaly == nil, "offline time counts across a reboot")

        clock.reboot(offlineFor: -500)
        (elapsed, anomaly, _) = TimeAccountant.advance(from: anchor, clock: clock)
        try expect(elapsed == 0 && anomaly == .wallBehindAfterReboot(seconds: 500))
    }),

    ("lockout grows exponentially and counts down with credited time", {
        var limiter = AttemptLimiter()
        limiter.recordFailure()
        limiter.recordFailure()
        try expect(!limiter.isLockedOut)
        limiter.recordFailure()
        try expect(limiter.lockoutRemaining == 30)
        limiter.recordFailure()
        try expect(limiter.lockoutRemaining == 60)
        limiter.elapse(59)
        try expect(limiter.isLockedOut)
        limiter.elapse(1)
        try expect(!limiter.isLockedOut)
        for _ in 0..<20 { limiter.recordFailure() }
        try expect(limiter.lockoutRemaining == AttemptLimiter.maxLockout)
    }),

    ("passwords are salted and verified", {
        let record = try PasswordHasher.makeRecord(password: "correct horse", iterations: 1000)
        let again = try PasswordHasher.makeRecord(password: "correct horse", iterations: 1000)
        try expect(record.salt != again.salt && record.hash != again.hash)
        try expect(PasswordHasher.verify("correct horse", against: record))
        try expect(!PasswordHasher.verify("correct horsE", against: record))
        try expectThrows(.passwordTooShort(minimum: 8)) { _ = try PasswordHasher.makeRecord(password: "short") }
    }),
]
