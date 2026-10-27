import CryptoKit
import Foundation

/// Chrome's native messaging framing: a 4-byte little-endian length, then that many bytes of UTF-8 JSON.
public enum NativeMessageFraming {
    /// Chrome rejects messages from a host larger than 1 MB.
    public static let maxOutgoing = 1024 * 1024
    /// Chrome caps messages to a host at 64 MiB; ours are tiny, so anything large is treated as corrupt.
    public static let maxIncoming = 1024 * 1024

    public static func encode(_ message: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        guard body.count <= maxOutgoing else { throw FocusError.storage("native message too large (\(body.count) bytes)") }
        var length = UInt32(body.count).littleEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Extracts every complete message at the front of `buffer`, leaving any partial message in place.
    public static func decode(from buffer: inout Data) throws -> [[String: Any]] {
        var messages: [[String: Any]] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<start + 4].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            guard length <= maxIncoming else { throw FocusError.storage("incoming native message too large (\(length) bytes)") }
            guard buffer.count >= 4 + length else { break }
            let body = buffer[(start + 4)..<(start + 4 + length)]
            buffer = Data(buffer[(start + 4 + length)...])
            guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw FocusError.storage("native message is not a JSON object")
            }
            messages.append(object)
        }
        return messages
    }
}

/// The last thing the browser extension reported. The agent (increment 3) uses its age to decide whether Chrome
/// is running without a working extension.
public struct BrowserHeartbeat: Codable, Equatable, Sendable {
    public var browser: String
    public var extensionOrigin: String
    public var extensionVersion: String
    public var incognitoAllowed: Bool
    public var rulesRevision: String
    public var ruleCount: Int
    public var wall: Date
    public var monotonic: TimeInterval
    public var bootID: String
    public var hostPID: Int32

    /// Seconds since this heartbeat, measured on the monotonic clock when possible.
    public func age(clock: ClockSource) -> TimeInterval {
        if bootID == clock.bootID() { return max(0, clock.monotonicNow() - monotonic) }
        return .infinity
    }
}

public final class HeartbeatStore {
    public let url: URL

    public init(directory: URL, browser: String = "chrome") {
        url = directory.appendingPathComponent("heartbeat-\(browser).json")
    }

    public func write(_ heartbeat: BrowserHeartbeat) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try AtomicFile.write(try StateStore.encoder.encode(heartbeat), to: url)
    }

    public func read() -> BrowserHeartbeat? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? StateStore.decoder.decode(BrowserHeartbeat.self, from: data)
    }
}

/// Protocol logic of the native messaging host, separate from stdin/stdout so it can be tested.
///
/// The extension can only *read* policy and report heartbeats. Nothing it sends can stop a session, change a
/// blocklist or see the accountability password.
public final class NativeHostSession {
    public static let protocolVersion = 1

    let engine: FocusEngine
    let heartbeats: HeartbeatStore
    let clock: ClockSource
    let origin: String
    let pid: Int32
    /// Identifies what the extension last received: rules plus the set of sessions (which changes the end time).
    var lastSentKey: String?

    public init(engine: FocusEngine, heartbeats: HeartbeatStore, origin: String, clock: ClockSource = SystemClock(),
                pid: Int32 = getpid()) {
        self.engine = engine
        self.heartbeats = heartbeats
        self.origin = origin
        self.clock = clock
        self.pid = pid
    }

    /// Replies to one message from the extension.
    public func handle(_ message: [String: Any]) -> [[String: Any]] {
        switch message["type"] as? String {
        case "hello":
            recordHeartbeat(message)
            return [policyMessage(refresh: true)]
        case "heartbeat":
            recordHeartbeat(message)
            // Re-send policy if the extension's rules don't match ours, e.g. after it reloaded.
            if let revision = message["rulesRevision"] as? String, revision != engine.policy().revision || lastSentKey == nil {
                return [policyMessage(refresh: true)]
            }
            return []
        case "getPolicy":
            return [policyMessage(refresh: true)]
        default:
            return [["type": "error", "message": "unknown message type"]]
        }
    }

    /// Called periodically: advances the engine and returns a policy message if anything the extension needs changed.
    public func poll() -> [String: Any]? {
        do { try engine.tick() } catch { return errorMessage(error) }
        return key(for: engine.policy()) == lastSentKey ? nil : policyMessage(refresh: false)
    }

    func policyMessage(refresh: Bool) -> [String: Any] {
        if refresh {
            do { try engine.tick() } catch { return errorMessage(error) }
        }
        let policy = engine.policy()
        lastSentKey = key(for: policy)
        return [
            "type": "policy",
            "protocol": Self.protocolVersion,
            "active": policy.active,
            "strict": policy.strict,
            "revision": policy.revision,
            "estimatedEnd": policy.estimatedEnd.map { $0.timeIntervalSince1970 * 1000 } ?? NSNull(),
            "domains": policy.blockedDomains,
            "exceptions": policy.exceptions,
            "rules": ChromeRuleCompiler.dnrRules(for: policy),
        ]
    }

    func key(for policy: EnforcementPolicy) -> String {
        policy.revision + "|" + policy.sessionIDs.map(\.uuidString).sorted().joined(separator: ",")
    }

    func recordHeartbeat(_ message: [String: Any]) {
        let heartbeat = BrowserHeartbeat(
            browser: "chrome", extensionOrigin: origin,
            extensionVersion: message["version"] as? String ?? "?",
            incognitoAllowed: message["incognitoAllowed"] as? Bool ?? false,
            rulesRevision: message["rulesRevision"] as? String ?? "",
            ruleCount: message["ruleCount"] as? Int ?? 0,
            wall: clock.wallNow(), monotonic: clock.monotonicNow(), bootID: clock.bootID(), hostPID: pid)
        try? heartbeats.write(heartbeat)
    }

    func errorMessage(_ error: Error) -> [String: Any] {
        ["type": "error", "message": String(describing: error)]
    }
}

/// Writes the per-user manifest Chrome uses to find the host. Nothing is written until `install` is called.
public enum NativeHostManifest {
    public static let name = "com.focusblocker.nmh"

    public static func chromeDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")
    }

    public static func contents(hostPath: String, extensionIDs: [String]) throws -> Data {
        let manifest: [String: Any] = [
            "name": name,
            "description": "Focus blocker native messaging host",
            "path": hostPath,
            "type": "stdio",
            "allowed_origins": extensionIDs.map { "chrome-extension://\($0)/" },
        ]
        return try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Chrome derives an extension's ID from its public key: SHA-256 of the DER key, first 16 bytes, each hex digit
    /// mapped 0–f → a–p. Setting `key` in manifest.json therefore pins the ID of an unpacked extension.
    public static func extensionID(publicKeyBase64: String) -> String? {
        guard let der = Data(base64Encoded: publicKeyBase64) else { return nil }
        let letters = Array("abcdefghijklmnop")
        return String(SHA256.hash(data: der).prefix(16).flatMap { [letters[Int($0 >> 4)], letters[Int($0 & 0x0F)]] })
    }

    /// Chrome extension IDs are 32 characters from a–p.
    public static func isValidExtensionID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { ("a"..."p").contains($0) }
    }
}
