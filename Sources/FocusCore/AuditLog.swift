import CryptoKit
import Foundation

public struct AuditEntry: Codable, Equatable, Identifiable, Sendable {
    public var seq: Int
    public var time: Date
    public var event: String
    public var detail: String
    /// HMAC over the previous entry's MAC plus this entry's fields, chaining every entry to the one before.
    public var mac: String

    public var id: Int { seq }
}

public enum AuditVerification: Equatable {
    case intact(count: Int)
    case broken(atLine: Int, reason: String)
}

/// Append-only, HMAC-chained JSON-lines log of session starts, unlocks, failures and anomalies.
///
/// Deleting the whole file can't be prevented on an admin account, but editing, reordering or removing
/// individual entries breaks the chain.
public final class AuditLog {
    public let url: URL
    let keyProvider: StateKeyProvider

    public init(url: URL, keyProvider: StateKeyProvider) {
        self.url = url
        self.keyProvider = keyProvider
    }

    public func append(_ event: String, _ detail: String = "", at time: Date) throws {
        let key = try keyProvider.key()
        let last = try entries().last
        var entry = AuditEntry(seq: (last?.seq ?? 0) + 1, time: time, event: event, detail: detail, mac: "")
        entry.mac = Self.mac(for: entry, previous: last?.mac ?? "", key: key)
        var line = try Self.encoder.encode(entry)
        line.append(0x0A)

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { throw FocusError.storage("open \(url.path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        let written = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, line.count) }
        guard written == line.count else { throw FocusError.storage("append to \(url.path) failed") }
        _ = fsync(fd)
    }

    public func entries() throws -> [AuditEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(AuditEntry.self, from: Data($0)) }
    }

    public func verify() throws -> AuditVerification {
        let key = try keyProvider.key()
        guard let data = try? Data(contentsOf: url) else { return .intact(count: 0) }
        var previous = ""
        var count = 0
        for (index, line) in data.split(separator: 0x0A).enumerated() {
            guard let entry = try? Self.decoder.decode(AuditEntry.self, from: Data(line)) else {
                return .broken(atLine: index + 1, reason: "unreadable entry")
            }
            guard entry.seq == count + 1 else { return .broken(atLine: index + 1, reason: "sequence gap") }
            guard entry.mac == Self.mac(for: entry, previous: previous, key: key) else {
                return .broken(atLine: index + 1, reason: "MAC mismatch")
            }
            previous = entry.mac
            count += 1
        }
        return .intact(count: count)
    }

    static func mac(for entry: AuditEntry, previous: String, key: SymmetricKey) -> String {
        let fields = [previous, String(entry.seq), String(entry.time.timeIntervalSince1970), entry.event, entry.detail]
        return Hashing.hmacHex(Data(fields.joined(separator: "\u{1F}").utf8), key: key)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
