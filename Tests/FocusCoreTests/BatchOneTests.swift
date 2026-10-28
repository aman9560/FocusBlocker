import Foundation
@testable import FocusCore

private func webPolicy(strict: Bool = true, domains: [String] = ["reddit.com"], active: Bool = true) -> EnforcementPolicy {
    EnforcementPolicy(active: active, strict: strict, sessionIDs: [], estimatedEnd: nil, blockedDomains: domains,
                      exceptions: [], blockedApps: [], revision: "r")
}

let batchOneTests: [(String, () throws -> Void)] = [
    ("other browsers close only in strict sessions that block websites", {
        for id in ["com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox", "com.apple.Safari.WebApp.1234-ABCD"] {
            try expect(BrowserGuard.reasonToCloseOtherBrowser(id, policy: webPolicy(), enabled: true) != nil, id)
        }
        try expect(BrowserGuard.reasonToCloseOtherBrowser("com.google.Chrome", policy: webPolicy(), enabled: true) == nil,
                   "Chrome is handled by the extension check instead")
        try expect(BrowserGuard.reasonToCloseOtherBrowser("com.apple.Safari", policy: webPolicy(strict: false), enabled: true) == nil)
        try expect(BrowserGuard.reasonToCloseOtherBrowser("com.apple.Safari", policy: webPolicy(domains: []), enabled: true) == nil)
        try expect(BrowserGuard.reasonToCloseOtherBrowser("com.apple.Safari", policy: webPolicy(active: false), enabled: true) == nil)
        try expect(BrowserGuard.reasonToCloseOtherBrowser("com.apple.Safari", policy: webPolicy(), enabled: false) == nil)
        try expect(BrowserGuard.reasonToCloseOtherBrowser("com.apple.TextEdit", policy: webPolicy(), enabled: true) == nil)
    }),

    ("the other-browsers setting can't be turned off during a strict session", {
        let fx = Fixture()
        let engine = try fx.engine()
        try expect(engine.state.settings.closeOtherBrowsers, "on by default")
        try engine.setCloseOtherBrowsers(false)
        try expect(!engine.state.settings.closeOtherBrowsers)
        try engine.setCloseOtherBrowsers(true)
        try engine.createBlocklist(name: "Web", domains: ["x.com"])
        try engine.startSession(blocklistNames: ["Web"], duration: 600, lock: .timer, strict: true)
        try expectThrows(.weakensActiveSession("turning off closing other browsers")) { try engine.setCloseOtherBrowsers(false) }
        try expect(try fx.engine().state.settings.closeOtherBrowsers, "still on after a restart")
        try expect(try fx.audit.entries().filter { $0.event == "settings.changed" }.count == 2)
    }),

    ("settings saved before the browser setting existed still load", {
        let old = Data(#"{"maxSessionDuration": 7200, "extensionGracePeriod": 45}"#.utf8)
        let settings = try JSONDecoder().decode(Settings.self, from: old)
        try expect(settings.maxSessionDuration == 7200 && settings.extensionGracePeriod == 45 && settings.closeOtherBrowsers)
        let off = try JSONDecoder().decode(Settings.self, from: Data(#"{"closeOtherBrowsers": false}"#.utf8))
        try expect(!off.closeOtherBrowsers && off.maxSessionDuration == 12 * 3600)
    }),

    ("session changes are noticed whoever caused them", {
        let fx = Fixture()
        let agentView = try fx.engine()
        let cli = try fx.engine()
        var tracker = SessionChangeTracker()
        try cli.createBlocklist(name: "Web", domains: ["x.com"])
        try cli.startSession(blocklistNames: ["Web"], duration: 120, lock: .none, strict: false)

        try agentView.tick()
        var change = tracker.update(agentView.state)
        try expect(change.started.isEmpty && change.ended.isEmpty, "sessions running at startup aren't re-announced")

        try cli.stopSessions(password: nil)
        try cli.startSession(blocklistNames: ["Web"], duration: 60, lock: .timer, strict: true)
        try agentView.tick()
        change = tracker.update(agentView.state)
        try expect(change.started.count == 1 && change.started[0].lock == .timer)
        try expect(change.ended.count == 1 && change.ended[0].endReason == .stoppedUnlocked)

        fx.clock.advance(60)
        try agentView.tick()
        change = tracker.update(agentView.state)
        try expect(change.started.isEmpty && change.ended.first?.endReason == .completed)
        try expect(tracker.update(agentView.state).ended.isEmpty, "each change is reported once")
    }),

    ("notification text", {
        var s = Session(id: UUID(), blocklistIDs: [], origin: .manual, lock: .timer, strict: true, startedAt: Date(),
                        duration: 5400, credited: 0, endedAt: nil, endReason: nil)
        try expect(FocusNotice.started(s, listNames: "Social") ==
                   .init(title: "Focus session started", body: "Social for 1 h 30 min. Timer-locked: normal stop is disabled; emergency failsafe is available."))
        s.endReason = .completed
        try expect(FocusNotice.ended(s, listNames: "Social").title == "Focus session complete")
        s.endReason = .failsafe
        try expect(FocusNotice.ended(s, listNames: "Social").title == "Focus session ended with failsafe")
        s.endReason = .unlockedWithPassword
        try expect(FocusNotice.ended(s, listNames: "Social").body.contains("accountability password"))
        try expect(FocusNotice.closed(appName: "Safari", reason: "only Chrome is allowed", until: nil).body == "Safari was closed: only Chrome is allowed.")
    }),

    ("imports Cold Turkey JSON exports block by block, plain lists, and refuses encoded files", {
        let export = Data("""
        {"blocks": {
            "Distractions": {"web": ["bsky.app", "https://www.reddit.com/", "youtube.com/*", "*.twitch.tv"], "exceptions": ["file://*.*", "reddit.com/r/swift"], "apps": []},
            "Games": {"web": ["roblox.com", "title:*Steam*"]},
            "Empty": {"web": []}
        }, "settings": {"theme": "system"}}
        """.utf8)
        let blocks = try BlocklistImport.load(export)
        try expect(blocks.map(\.name) == ["Distractions", "Games"], "\(blocks.map(\.name))")
        try expect(blocks[0].result.domains == ["bsky.app", "reddit.com", "twitch.tv", "youtube.com"])
        try expect(blocks[0].result.exceptions == ["reddit.com/r/swift"] && blocks[0].result.skipped == ["file://*.*"])
        try expect(blocks[1].result.domains == ["roblox.com"] && blocks[1].result.skipped == ["title:*Steam*"])
        try expect(blocks[1].targetName(override: nil) == "Games" && blocks[1].targetName(override: "Mine") == "Mine")

        let plain = try BlocklistImport.load(Data("# my sites\nnews.ycombinator.com, x.com\n\ninstagram.com\n".utf8))
        try expect(plain.count == 1 && plain[0].name == nil && plain[0].targetName(override: nil) == "Imported")
        try expect(plain[0].result.domains == ["instagram.com", "news.ycombinator.com", "x.com"])

        do {
            _ = try BlocklistImport.load(Data("CTB1788C3372".utf8))
            throw TestFailure(description: "encoded file accepted")
        } catch BlocklistImport.ImportError.encoded {}
        do {
            _ = try BlocklistImport.load(Data("{}".utf8))
            throw TestFailure(description: "empty file accepted")
        } catch BlocklistImport.ImportError.empty {}
    }),

    ("importing into an active strict blocklist adds sites but no exceptions", {
        let fx = Fixture()
        let engine = try fx.engine()
        try engine.importRules(BlocklistImport.Result(domains: ["x.com"], exceptions: [], skipped: []), intoBlocklistNamed: "Distractions")
        try engine.startSession(blocklistNames: ["Distractions"], duration: 600, lock: .timer, strict: true)
        try engine.importRules(BlocklistImport.Result(domains: ["reddit.com"], exceptions: [], skipped: []), intoBlocklistNamed: "Distractions")
        try expect(try engine.blocklist(named: "Distractions").domains == ["reddit.com", "x.com"])
        try expectThrows(.weakensActiveSession("adding exceptions")) {
            try engine.importRules(BlocklistImport.Result(domains: [], exceptions: ["x.com/home"], skipped: []), intoBlocklistNamed: "Distractions")
        }
    }),
]

let allWebsitesTests: [(String, () throws -> Void)] = [
    ("an all-websites rule turns exceptions into an allowlist", {
        for raw in ["*", "*.*", "https://*.*"] { try expect(try DomainRule(parsing: raw).isAllWebsites, raw) }
        try expectThrows(.invalidRule("file://*.*")) { _ = try DomainRule(parsing: "file://*.*") }
        try expectThrows(.invalidRule("file://*")) { _ = try DomainRule(parsing: "file://*") }

        let list = Blocklist(name: "Distractions", domains: try DomainRule.normalize(["*.*", "google.com", "youtube.com"]),
                             exceptions: try DomainRule.normalize(["docs.google.com", "mail.google.com", "chat.openai.com"]))
        let session = Session(id: UUID(), blocklistIDs: [list.id], origin: .manual, lock: .timer, strict: true,
                              startedAt: Date(), duration: 600, credited: 0, endedAt: nil, endReason: nil)
        let policy = EnforcementPolicy.build(sessions: [session], blocklists: [list], now: Date())
        try expect(policy.blockedDomains.first == "*")
        try expect(policy.exceptions == ["chat.openai.com", "docs.google.com", "mail.google.com"], "exceptions survive")
        for (url, blocked) in [("https://example.com/", true), ("https://news.ycombinator.com/x", true), ("https://google.com/", true),
                               ("https://docs.google.com/document/d/1", false), ("https://mail.google.com/", false),
                               ("https://chat.openai.com/c/1", false), ("http://neverssl.com/", true)] {
            try expect(policy.blocks(URL(string: url)!) == blocked, url)
        }

        let rules = ChromeRuleCompiler.dnrRules(for: policy)
        let conditions = rules.map { $0["condition"] as! [String: Any] }
        let actions = rules.map { ($0["action"] as! [String: Any])["type"] as! String }
        try expect(conditions[0]["urlFilter"] as? String == "|http" && conditions[0]["resourceTypes"] as? [String] == ["main_frame"])
        try expect(conditions[1]["resourceTypes"] as? [String] == ["sub_frame"], "everything else isn't blocked wholesale")
        try expect(actions.filter { $0 == "allowAllRequests" }.count == 3, "each exception page may load what it needs")
        try expect(Set(rules.map { $0["id"] as! Int }).count == rules.count)
    }),
]
