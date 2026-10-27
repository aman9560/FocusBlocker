import Foundation

/// Reads website rules from a file: a Cold Turkey export (made with Cold Turkey's own "Export all blocks to
/// file…") or a plain list with one site per line. Entries that aren't website rules, such as Cold Turkey's
/// window-title or file rules, are reported as skipped rather than guessed at.
public enum BlocklistImport {
    public struct Result: Equatable {
        public var domains: [String] = []
        public var exceptions: [String] = []
        public var skipped: [String] = []
    }

    /// One block found in an import file. `name` is set when the file names its blocks (Cold Turkey JSON exports do).
    public struct NamedResult: Equatable {
        public var name: String?
        public var result: Result
    }

    public enum ImportError: Error, Equatable, CustomStringConvertible {
        case encoded
        case empty

        public var description: String {
            switch self {
            case .encoded:
                return "This file is in Cold Turkey's encoded format, which Focus Blocker doesn't read. Copy the websites from the block in Cold Turkey into a text file, one per line, and import that instead."
            case .empty:
                return "No website rules were found in this file."
            }
        }
    }

    /// Splits a file into blocks: one per entry of a top-level `blocks` object, otherwise a single unnamed block.
    public static func load(_ data: Data) throws -> [NamedResult] {
        let head = String(decoding: data.prefix(8), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("CTB") { throw ImportError.encoded }

        var named: [NamedResult] = []
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let blocks = json["blocks"] as? [String: Any] {
            for name in blocks.keys.sorted() {
                guard let block = blocks[name],
                      let blockData = try? JSONSerialization.data(withJSONObject: ["block": block]) else { continue }
                let result = parse(blockData)
                if !result.domains.isEmpty || !result.exceptions.isEmpty { named.append(NamedResult(name: name, result: result)) }
            }
        } else {
            let result = parse(data)
            if !result.domains.isEmpty || !result.exceptions.isEmpty { named.append(NamedResult(name: nil, result: result)) }
        }
        guard !named.isEmpty else { throw ImportError.empty }
        return named
    }

    static let domainKeys: Set<String> = ["web", "websites", "blocklist", "domains", "sites"]
    static let exceptionKeys: Set<String> = ["exceptions", "exceptionlist", "allow", "allowlist"]

    public static func parse(_ data: Data) -> Result {
        var rawDomains: [String] = []
        var rawExceptions: [String] = []
        if let json = try? JSONSerialization.jsonObject(with: data) {
            collect(json, domains: &rawDomains, exceptions: &rawExceptions)
        } else {
            let text = String(decoding: data, as: UTF8.self)
            rawDomains = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .flatMap { $0.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" }).map(String.init) }
        }

        var result = Result()
        result.domains = normalize(rawDomains, skipped: &result.skipped)
        result.exceptions = normalize(rawExceptions, skipped: &result.skipped)
        return result
    }

    /// Walks the JSON, taking string arrays stored under known keys at any depth.
    static func collect(_ value: Any, domains: inout [String], exceptions: inout [String]) {
        if let dict = value as? [String: Any] {
            for (key, child) in dict {
                if let strings = child as? [String] {
                    if domainKeys.contains(key.lowercased()) { domains += strings }
                    if exceptionKeys.contains(key.lowercased()) { exceptions += strings }
                } else {
                    collect(child, domains: &domains, exceptions: &exceptions)
                }
            }
        } else if let array = value as? [Any] {
            for child in array { collect(child, domains: &domains, exceptions: &exceptions) }
        }
    }

    static func normalize(_ raw: [String], skipped: inout [String]) -> [String] {
        var rules = Set<DomainRule>()
        for entry in raw {
            var text = entry.trimmingCharacters(in: .whitespaces)
            // "example.com/*" means the whole site.
            while text.hasSuffix("/*") || text.hasSuffix("*") { text.removeLast(text.hasSuffix("/*") ? 2 : 1) }
            if let rule = try? DomainRule(parsing: text) {
                rules.insert(rule)
            } else if !entry.isEmpty {
                skipped.append(entry)
            }
        }
        return rules.sorted().map(\.description)
    }
}

extension BlocklistImport.NamedResult {
    /// The Focus blocklist this block goes into: an explicit name, else the block's own name, else "Imported".
    public func targetName(override: String?) -> String {
        override ?? name ?? "Imported"
    }
}

extension FocusEngine {
    /// Adds imported rules to the named blocklist, creating it if needed. Existing entries are kept, so importing
    /// during a strict session only ever blocks more (new exceptions are refused then, as for any edit).
    @discardableResult
    public func importRules(_ result: BlocklistImport.Result, intoBlocklistNamed name: String) throws -> Blocklist {
        guard var list = try? blocklist(named: name) else {
            return try createBlocklist(name: name, domains: result.domains, exceptions: result.exceptions)
        }
        list.domains = Array(Set(list.domains + result.domains))
        list.exceptions = Array(Set(list.exceptions + result.exceptions))
        try updateBlocklist(list)
        return try blocklist(named: name)
    }
}
