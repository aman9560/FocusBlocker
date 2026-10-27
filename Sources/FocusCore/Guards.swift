import Foundation

/// What the agent knows about one running app.
public struct RunningAppInfo: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String?
    /// Team identifier from the app's code signature, when it has one.
    public var teamID: String?

    public init(pid: Int32, bundleID: String?, teamID: String?) {
        self.pid = pid
        self.bundleID = bundleID
        self.teamID = teamID
    }
}

/// Decides which running apps an active session blocks. Pure logic, so it can be tested without launching apps.
public enum AppGuard {
    /// Apps the guard never quits, and blocklists refuse to contain, so a session can't make the Mac unusable.
    public static let protectedBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver",
        "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.SecurityAgent",
        "com.apple.systempreferences", "com.apple.Settings", "com.apple.ActivityMonitor", "com.apple.Terminal",
        "com.apple.WindowManager", "com.apple.Spotlight", "com.apple.coreservices.uiagent",
        "com.focusblocker.app",
    ]

    public static func isProtected(_ bundleID: String) -> Bool {
        protectedBundleIDs.contains(bundleID) || bundleID.hasPrefix("com.focusblocker.")
    }

    /// The rule that blocks `app`, if any. A rule with a team ID only matches apps signed by that team.
    public static func blockingRule(for app: RunningAppInfo, policy: EnforcementPolicy) -> AppRule? {
        guard policy.active, let bundleID = app.bundleID, !isProtected(bundleID) else { return nil }
        return policy.blockedApps.first { rule in
            rule.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame && (rule.teamID == nil || rule.teamID == app.teamID)
        }
    }
}

/// Decides whether Chrome is running without a working Focus extension during a strict session.
public enum BrowserGuard {
    /// Chrome channels the agent watches. The native host is only registered for stable Chrome, so the other
    /// channels can never report a heartbeat and are closed during strict sessions.
    public static let chromeBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
    ]

    public struct Observation: Equatable, Sendable {
        public var hostInstalled: Bool
        /// Seconds since the extension's last heartbeat; `nil` if it never reported.
        public var heartbeatAge: TimeInterval?
        /// Seconds since this Chrome process launched.
        public var runningFor: TimeInterval
        public var launchedWithExtensionsDisabled: Bool
        public var isStableChrome: Bool

        public init(hostInstalled: Bool, heartbeatAge: TimeInterval?, runningFor: TimeInterval,
                    launchedWithExtensionsDisabled: Bool, isStableChrome: Bool) {
            self.hostInstalled = hostInstalled
            self.heartbeatAge = heartbeatAge
            self.runningFor = runningFor
            self.launchedWithExtensionsDisabled = launchedWithExtensionsDisabled
            self.isStableChrome = isStableChrome
        }
    }

    /// The reason to close Chrome, or `nil` to leave it. Only strict sessions act, and only once the host is
    /// installed, so a missing setup never closes Chrome unexpectedly.
    public static func reasonToClose(_ o: Observation, policy: EnforcementPolicy, gracePeriod: TimeInterval) -> String? {
        guard policy.active, policy.strict, !policy.blockedDomains.isEmpty, o.hostInstalled else { return nil }
        if o.launchedWithExtensionsDisabled { return "Chrome was started with extensions disabled" }
        guard o.runningFor >= gracePeriod else { return nil }
        if !o.isStableChrome { return "this Chrome channel can't run the Focus extension" }
        guard let age = o.heartbeatAge, age <= gracePeriod else { return "the Focus extension isn't responding" }
        return nil
    }
}

extension BrowserGuard {
    /// Browsers that can't run the Focus Chrome extension. During strict sessions that block websites they are
    /// closed outright, otherwise they would be an open door around the website rules.
    public static let otherBrowserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "company.thebrowser.Browser", "company.thebrowser.dia",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
        "com.operasoftware.Opera", "com.operasoftware.OperaGX", "com.operasoftware.OperaNext",
        "com.vivaldi.Vivaldi", "org.chromium.Chromium", "app.zen-browser.zen", "net.waterfox.waterfox",
        "io.gitlab.librewolf-community", "org.torproject.torbrowser", "com.kagi.kagimacOS",
        "com.duckduckgo.macos.browser", "ai.perplexity.comet", "com.openai.atlas", "com.sigmaos.sigmaos.macos",
        "ru.yandex.desktop.yandex-browser",
    ]

    /// Safari web apps ("Add to Dock") get bundle IDs under this prefix.
    static let otherBrowserPrefixes = ["com.apple.Safari.WebApp."]

    public static func isOtherBrowser(_ bundleID: String) -> Bool {
        otherBrowserBundleIDs.contains(bundleID) || otherBrowserPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// The reason to close a non-Chrome browser, or `nil` to leave it.
    public static func reasonToCloseOtherBrowser(_ bundleID: String, policy: EnforcementPolicy, enabled: Bool) -> String? {
        guard enabled, policy.active, policy.strict, !policy.blockedDomains.isEmpty, isOtherBrowser(bundleID) else { return nil }
        return "only Chrome with the Focus extension is allowed during strict sessions"
    }
}
