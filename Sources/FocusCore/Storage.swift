import CryptoKit
import Foundation
import Security

enum Hashing {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hmacHex(_ data: Data, key: SymmetricKey) -> String {
        HMAC<SHA256>.authenticationCode(for: data, using: key).map { String(format: "%02x", $0) }.joined()
    }

    static func hmacValid(_ data: Data, hex: String, key: SymmetricKey) -> Bool {
        guard let mac = Data(hexString: hex) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: data, using: key)
    }
}

extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

/// Supplies the key that authenticates saved state and the audit log.
///
/// On an admin account any key the user's processes can read, the user can read too, so the HMAC makes
/// edits detectable rather than impossible. The root daemon increment moves the key out of the user's reach.
public protocol StateKeyProvider {
    func key() throws -> SymmetricKey
}

/// Keeps the key in a 0600 file inside the 0700 state folder. See `FocusPaths.keyFile` for why it isn't in the keychain.
public struct FileKeyProvider: StateKeyProvider {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func key() throws -> SymmetricKey {
        if let data = try? Data(contentsOf: url), data.count == 32 { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try AtomicFile.write(key.withUnsafeBytes { Data($0) }, to: url)
        return key
    }
}

enum AtomicFile {
    /// Writes to a temporary file, flushes it to disk, then renames it into place, so readers never see a partial file.
    static func write(_ data: Data, to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw FocusError.storage("open \(tmp.path): \(String(cString: strerror(errno)))") }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        let synced = fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0
        close(fd)
        guard written == data.count, synced else {
            unlink(tmp.path)
            throw FocusError.storage("write \(tmp.path) failed")
        }
        guard rename(tmp.path, url.path) == 0 else { throw FocusError.storage("rename to \(url.path): \(String(cString: strerror(errno)))") }
    }
}

public enum LoadOutcome: Equatable {
    case fresh
    case loaded
    /// The primary file was missing or failed verification; the previous good copy was used.
    case recoveredFromBackup(reason: String)
}

struct ReadFailure: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

/// HMAC-authenticated, atomically written state with one last-known-good backup.
public final class StateStore {
    struct Envelope: Codable {
        var version: Int
        var payload: Data
        var mac: String
    }

    public let directory: URL
    let keyProvider: StateKeyProvider
    var primary: URL { directory.appendingPathComponent("state.json") }
    var backup: URL { directory.appendingPathComponent("state.prev.json") }

    public init(directory: URL, keyProvider: StateKeyProvider) {
        self.directory = directory
        self.keyProvider = keyProvider
    }

    /// Runs `body` while holding an exclusive `flock` on the state folder, serializing every process that shares it.
    /// Not reentrant: never call it from inside `body`.
    public func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(".lock").path
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw FocusError.storage("open \(path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw FocusError.storage("lock \(path): \(String(cString: strerror(errno)))") }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    public func load() throws -> (FocusState, LoadOutcome) {
        let key = try keyProvider.key()
        let fm = FileManager.default
        if !fm.fileExists(atPath: primary.path) && !fm.fileExists(atPath: backup.path) { return (FocusState(), .fresh) }

        var primaryProblem = "missing"
        if fm.fileExists(atPath: primary.path) {
            switch read(primary, key: key) {
            case .success(let state): return (state, .loaded)
            case .failure(let why): primaryProblem = why.reason
            }
        }
        switch read(backup, key: key) {
        case .success(let state): return (state, .recoveredFromBackup(reason: "state.json \(primaryProblem)"))
        case .failure(let why): throw FocusError.stateTampered("state.json \(primaryProblem); state.prev.json \(why.reason)")
        }
    }

    public func save(_ state: FocusState) throws {
        let key = try keyProvider.key()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let payload = try Self.encoder.encode(state)
        let envelope = Envelope(version: 1, payload: payload, mac: Hashing.hmacHex(payload, key: key))
        let data = try Self.encoder.encode(envelope)

        // Keep the current file as the backup only if it still verifies, so a tampered file never becomes "last good".
        if case .success = read(primary, key: key) {
            _ = rename(primary.path, backup.path)
        }
        try AtomicFile.write(data, to: primary)
    }

    func read(_ url: URL, key: SymmetricKey) -> Result<FocusState, ReadFailure> {
        guard let data = try? Data(contentsOf: url) else { return .failure(ReadFailure("missing")) }
        guard let env = try? Self.decoder.decode(Envelope.self, from: data) else { return .failure(ReadFailure("unreadable")) }
        guard Hashing.hmacValid(env.payload, hex: env.mac, key: key) else { return .failure(ReadFailure("failed its HMAC check")) }
        guard let state = try? Self.decoder.decode(FocusState.self, from: env.payload) else { return .failure(ReadFailure("has an unknown format")) }
        return .success(state)
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
