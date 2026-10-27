import Foundation
@testable import FocusCore

private func policy(apps: [AppRule] = [], domains: [String] = ["reddit.com"], strict: Bool = true, active: Bool = true) -> EnforcementPolicy {
    EnforcementPolicy(active: active, strict: strict, sessionIDs: [], estimatedEnd: nil, blockedDomains: domains,
                      exceptions: [], blockedApps: apps, revision: "r")
}

private func chrome(host: Bool = true, age: TimeInterval? = 5, runningFor: TimeInterval = 120,
                    disabled: Bool = false, stable: Bool = true) -> BrowserGuard.Observation {
    BrowserGuard.Observation(hostInstalled: host, heartbeatAge: age, runningFor: runningFor,
                             launchedWithExtensionsDisabled: disabled, isStableChrome: stable)
}

let guardTests: [(String, () throws -> Void)] = [
    ("the app guard matches bundle IDs, optional team IDs, and only during sessions", {
        let slack = RunningAppInfo(pid: 10, bundleID: "com.tinyspeck.slackmacgap", teamID: "BQR82RBBHL")
        try expect(AppGuard.blockingRule(for: slack, policy: policy(apps: [AppRule(bundleID: "com.tinyspeck.slackmacgap")])) != nil)
        try expect(AppGuard.blockingRule(for: slack, policy: policy(apps: [AppRule(bundleID: "COM.TINYSPECK.SLACKMACGAP")])) != nil)
        try expect(AppGuard.blockingRule(for: slack, policy: policy(apps: [AppRule(bundleID: "com.tinyspeck.slackmacgap", teamID: "OTHER")])) == nil,
                   "a different signer doesn't match")
        try expect(AppGuard.blockingRule(for: slack, policy: policy(apps: [AppRule(bundleID: "com.tinyspeck.slackmacgap")], active: false)) == nil)
        try expect(AppGuard.blockingRule(for: RunningAppInfo(pid: 1, bundleID: nil, teamID: nil), policy: policy()) == nil)
    }),

    ("protected apps are never closed and can't be added to blocklists", {
        let finder = RunningAppInfo(pid: 2, bundleID: "com.apple.finder", teamID: nil)
        try expect(AppGuard.blockingRule(for: finder, policy: policy(apps: [AppRule(bundleID: "com.apple.finder")])) == nil)
        try expect(AppGuard.isProtected("com.focusblocker.anything"))

        let fx = Fixture()
        let engine = try fx.engine()
        try expectThrows(.protectedApp("com.apple.Terminal")) {
            try engine.createBlocklist(name: "Bad", apps: [AppRule(bundleID: "com.apple.Terminal")])
        }
        var list = try engine.createBlocklist(name: "Ok", apps: [AppRule(bundleID: "com.valvesoftware.steam")])
        list.apps.append(AppRule(bundleID: "com.apple.systempreferences"))
        try expectThrows(.protectedApp("com.apple.systempreferences")) { try engine.updateBlocklist(list) }
    }),

    ("chrome is closed in strict sessions only when the extension isn't working", {
        let grace: TimeInterval = 30
        try expect(BrowserGuard.reasonToClose(chrome(), policy: policy(), gracePeriod: grace) == nil, "healthy")
        try expect(BrowserGuard.reasonToClose(chrome(age: nil), policy: policy(), gracePeriod: grace) == "the Focus extension isn't responding")
        try expect(BrowserGuard.reasonToClose(chrome(age: 31), policy: policy(), gracePeriod: grace) != nil)
        try expect(BrowserGuard.reasonToClose(chrome(age: nil, runningFor: 10), policy: policy(), gracePeriod: grace) == nil,
                   "a freshly launched Chrome gets the grace period to start the extension")
        try expect(BrowserGuard.reasonToClose(chrome(runningFor: 1, disabled: true), policy: policy(), gracePeriod: grace)
                   == "Chrome was started with extensions disabled")
        try expect(BrowserGuard.reasonToClose(chrome(stable: false), policy: policy(), gracePeriod: grace) != nil)

        try expect(BrowserGuard.reasonToClose(chrome(age: nil), policy: policy(strict: false), gracePeriod: grace) == nil, "not strict")
        try expect(BrowserGuard.reasonToClose(chrome(age: nil), policy: policy(active: false), gracePeriod: grace) == nil, "no session")
        try expect(BrowserGuard.reasonToClose(chrome(host: false, age: nil), policy: policy(), gracePeriod: grace) == nil,
                   "never closes Chrome before the host is set up")
        try expect(BrowserGuard.reasonToClose(chrome(age: nil), policy: policy(domains: []), gracePeriod: grace) == nil,
                   "a session that blocks no websites leaves Chrome alone")
    }),
]
