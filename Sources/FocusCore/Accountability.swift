import CommonCrypto
import Foundation
import Security

/// Salted PBKDF2-SHA256 hash of the accountability password. The password itself is never stored.
public struct PasswordRecord: Codable, Equatable, Sendable {
    public var salt: Data
    public var iterations: Int
    public var hash: Data
}

public enum PasswordHasher {
    public static let defaultIterations = 600_000
    public static let minimumLength = 8

    public static func makeRecord(password: String, iterations: Int = defaultIterations) throws -> PasswordRecord {
        guard password.count >= minimumLength else { throw FocusError.passwordTooShort(minimum: minimumLength) }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw FocusError.randomFailed }
        return PasswordRecord(salt: salt, iterations: iterations, hash: derive(password, salt: salt, iterations: iterations))
    }

    public static func verify(_ password: String, against record: PasswordRecord) -> Bool {
        let candidate = derive(password, salt: record.salt, iterations: record.iterations)
        guard candidate.count == record.hash.count else { return false }
        // Constant-time comparison.
        var diff: UInt8 = 0
        for (a, b) in zip(candidate, record.hash) { diff |= a ^ b }
        return diff == 0
    }

    static func derive(_ password: String, salt: Data, iterations: Int) -> Data {
        let pw = Array(password.utf8).map { Int8(bitPattern: $0) }
        var out = [UInt8](repeating: 0, count: 32)
        salt.withUnsafeBytes { saltPtr in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count,
                                     saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &out, out.count)
        }
        return Data(out)
    }
}

/// Exponential lockout after repeated wrong passwords. Counts down with credited time, not the wall clock.
public struct AttemptLimiter: Codable, Equatable, Sendable {
    public static let freeAttempts = 3
    public static let baseLockout: TimeInterval = 30
    public static let maxLockout: TimeInterval = 3600

    public var failures = 0
    public var lockoutRemaining: TimeInterval = 0

    public init() {}

    public var isLockedOut: Bool { lockoutRemaining > 0 }

    public mutating func recordFailure() {
        failures += 1
        guard failures >= Self.freeAttempts else { return }
        let exponent = Double(failures - Self.freeAttempts)
        lockoutRemaining = min(Self.maxLockout, Self.baseLockout * pow(2, exponent))
    }

    public mutating func recordSuccess() {
        failures = 0
        lockoutRemaining = 0
    }

    public mutating func elapse(_ seconds: TimeInterval) {
        lockoutRemaining = max(0, lockoutRemaining - seconds)
    }
}
