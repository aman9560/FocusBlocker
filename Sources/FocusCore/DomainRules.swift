import Foundation

/// A website rule: a host (always including its subdomains) plus an optional path prefix.
public struct DomainRule: Hashable, Comparable, CustomStringConvertible, Sendable {
    public let host: String
    /// Starts with `/`, no trailing slash, no query. `nil` blocks the whole host.
    public let pathPrefix: String?

    /// The rule that matches every website, written `*` (Cold Turkey writes it `*.*`). Combined with exceptions it
    /// turns a blocklist into an allowlist.
    public static let allWebsites = "*"

    public var isAllWebsites: Bool { host == Self.allWebsites }

    /// Accepts loose input such as `https://www.Reddit.com/r/all/?x=1`, `*.reddit.com` or `youtube.com/shorts`.
    public init(parsing raw: String) throws {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") {
            // Only web addresses are rules. This keeps `file://*.*` from being read as "every website".
            guard ["http", "https"].contains(text[..<scheme.lowerBound]) else { throw FocusError.invalidRule(raw) }
            text = String(text[scheme.upperBound...])
        }
        if ["*", "*.*", "*/", "*.*/"].contains(text) {
            host = Self.allWebsites
            pathPrefix = nil
            return
        }
        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = String(text[..<cut]) }
        if text.hasPrefix("*.") { text.removeFirst(2) }

        let slash = text.firstIndex(of: "/")
        var host = String(text[..<(slash ?? text.endIndex)])
        var path = slash.map { String(text[$0...]) }

        if let colon = host.lastIndex(of: ":"), host[host.index(after: colon)...].allSatisfy(\.isNumber) { host = String(host[..<colon]) }
        if host.hasSuffix(".") { host.removeLast() }
        // `www.` is dropped so a rule always covers the bare domain and every subdomain.
        if host.hasPrefix("www.") { host.removeFirst(4) }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard host.contains("."), !host.hasPrefix("."), !host.contains(".."),
              host.unicodeScalars.allSatisfy(allowed.contains) else { throw FocusError.invalidRule(raw) }

        while path?.hasSuffix("/") == true { path?.removeLast() }
        if path?.isEmpty == true { path = nil }
        if let p = path, p.contains(where: { $0 == "*" || $0 == "|" || $0 == "^" || $0 == " " }) { throw FocusError.invalidRule(raw) }

        self.host = host
        self.pathPrefix = path
    }

    public var description: String { host + (pathPrefix ?? "") }

    public static func < (a: DomainRule, b: DomainRule) -> Bool { a.description < b.description }

    public func coversHost(_ other: String) -> Bool { isAllWebsites || other == host || other.hasSuffix("." + host) }

    public func matches(host urlHost: String, path urlPath: String) -> Bool {
        var h = urlHost.lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        guard coversHost(h) else { return false }
        guard let prefix = pathPrefix else { return true }
        let p = urlPath.lowercased()
        return p == prefix || p.hasPrefix(prefix + "/") || p.hasPrefix(prefix + "?")
    }

    /// True when every URL this rule matches is also matched by `broader`.
    public func isCovered(by broader: DomainRule) -> Bool {
        guard broader.coversHost(host) else { return false }
        guard let bp = broader.pathPrefix else { return true }
        guard let p = pathPrefix else { return false }
        return p == bp || p.hasPrefix(bp + "/")
    }

    public static func normalize(_ raw: [String]) throws -> [String] {
        Array(Set(try raw.map { try DomainRule(parsing: $0) })).sorted().map(\.description)
    }
}

/// What the enforcement layers (Chrome extension, app guard) should do right now.
public struct EnforcementPolicy: Codable, Equatable, Sendable {
    public var active: Bool
    public var strict: Bool
    public var sessionIDs: [UUID]
    /// Latest end among active sessions, estimated from remaining credited time.
    public var estimatedEnd: Date?
    public var blockedDomains: [String]
    public var exceptions: [String]
    public var blockedApps: [AppRule]
    /// Changes whenever the rule set changes, so clients can skip redundant updates.
    public var revision: String

    /// Same decision Chrome reaches with the compiled rules: a matching block rule and no matching exception.
    public func blocks(_ url: URL) -> Bool {
        guard active, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        let matches: (String) -> Bool = { raw in (try? DomainRule(parsing: raw))?.matches(host: host, path: path) ?? false }
        return blockedDomains.contains(where: matches) && !exceptions.contains(where: matches)
    }

    public static let inactive = EnforcementPolicy(active: false, strict: false, sessionIDs: [], estimatedEnd: nil,
                                                   blockedDomains: [], exceptions: [], blockedApps: [], revision: "inactive")

    /// Builds the combined policy. An exception only survives if every active list that blocks it also excepts it,
    /// so one list's exception can never unblock a site another list blocks.
    public static func build(sessions: [Session], blocklists: [Blocklist], now: Date) -> EnforcementPolicy {
        guard !sessions.isEmpty else { return .inactive }
        let byID = Dictionary(uniqueKeysWithValues: blocklists.map { ($0.id, $0) })
        let lists = Array(Set(sessions.flatMap(\.blocklistIDs))).compactMap { byID[$0] }

        let parse: ([String]) -> [DomainRule] = { $0.compactMap { try? DomainRule(parsing: $0) } }
        let blocked = Set(lists.flatMap { parse($0.domains) })
        var exceptions = Set<DomainRule>()
        for exception in Set(lists.flatMap { parse($0.exceptions) }) {
            let survives = lists.allSatisfy { list in
                let blocksIt = parse(list.domains).contains { exception.isCovered(by: $0) || $0.isCovered(by: exception) }
                return !blocksIt || parse(list.exceptions).contains { exception.isCovered(by: $0) }
            }
            if survives { exceptions.insert(exception) }
        }

        let apps = Array(Set(lists.flatMap(\.apps))).sorted { $0.bundleID < $1.bundleID }
        let domains = blocked.sorted().map(\.description)
        let exc = exceptions.sorted().map(\.description)
        let revisionSource = (domains + ["|"] + exc + ["|"] + apps.map { $0.bundleID + ($0.teamID ?? "") }).joined(separator: "\n")
        return EnforcementPolicy(
            active: true,
            strict: sessions.contains(where: \.strict),
            sessionIDs: sessions.map(\.id),
            estimatedEnd: sessions.map { now.addingTimeInterval($0.remaining) }.max(),
            blockedDomains: domains,
            exceptions: exc,
            blockedApps: apps,
            revision: Hashing.sha256Hex(Data(revisionSource.utf8)).prefix(16).description)
    }
}

/// Compiles a policy into Chrome `declarativeNetRequest` dynamic rules.
public enum ChromeRuleCompiler {
    public static let blockPagePath = "/blocked.html"
    static let subresourceTypes = ["sub_frame", "xmlhttprequest", "websocket", "media", "image", "script", "stylesheet", "font", "object", "ping", "other"]

    public static func dnrRules(for policy: EnforcementPolicy) -> [[String: Any]] {
        guard policy.active else { return [] }
        var rules: [[String: Any]] = []
        var nextID = 1
        func add(_ priority: Int, _ action: [String: Any], _ condition: [String: Any]) {
            rules.append(["id": nextID, "priority": priority, "action": action, "condition": condition])
            nextID += 1
        }
        let blocksAll = policy.blockedDomains.contains(DomainRule.allWebsites)
        for raw in policy.blockedDomains {
            guard let rule = try? DomainRule(parsing: raw) else { continue }
            if rule.isAllWebsites {
                // Only pages and frames: blocking every subresource would also break the excepted sites, which load
                // scripts and images from many other domains.
                add(1, ["type": "redirect", "redirect": ["extensionPath": blockPagePath]], ["urlFilter": "|http", "resourceTypes": ["main_frame"]])
                add(1, ["type": "block"], ["urlFilter": "|http", "resourceTypes": ["sub_frame"]])
                continue
            }
            let target = condition(for: rule)
            add(1, ["type": "redirect", "redirect": ["extensionPath": blockPagePath]], target.merging(["resourceTypes": ["main_frame"]]) { $1 })
            add(1, ["type": "block"], target.merging(["resourceTypes": subresourceTypes]) { $1 })
        }
        // Higher priority so exceptions win over blocks.
        for raw in policy.exceptions {
            guard let rule = try? DomainRule(parsing: raw) else { continue }
            add(2, ["type": "allow"], condition(for: rule).merging(["resourceTypes": ["main_frame"] + subresourceTypes]) { $1 })
            if blocksAll {
                // Lets an excepted page load everything it needs, from any domain.
                add(2, ["type": "allowAllRequests"], condition(for: rule).merging(["resourceTypes": ["main_frame", "sub_frame"]]) { $1 })
            }
        }
        return rules
    }

    static func condition(for rule: DomainRule) -> [String: Any] {
        if let path = rule.pathPrefix {
            // `||` anchors at the host or any subdomain; `^` stops `/shorts` from matching `/shortstack`.
            return ["urlFilter": "||\(rule.host)\(path)^"]
        }
        return ["requestDomains": [rule.host]]
    }

    public static func json(for policy: EnforcementPolicy) throws -> Data {
        try JSONSerialization.data(withJSONObject: dnrRules(for: policy), options: [.prettyPrinted, .sortedKeys])
    }
}
