import Foundation

public enum FocusError: Error, Equatable, CustomStringConvertible {
    case passwordTooShort(minimum: Int)
    case randomFailed
    case noAccountabilityPassword
    case wrongPassword
    case lockedOut(remaining: TimeInterval)
    case passwordChangeBlockedDuringSession
    case invalidDuration(maximum: TimeInterval)
    case unknownBlocklist(String)
    case unknownSession(UUID)
    case unknownSchedule(String)
    case duplicateName(String)
    case timerLocked(remaining: TimeInterval)
    case weakensActiveSession(String)
    case invalidRule(String)
    case protectedApp(String)
    case invalidSchedule(String)
    case stateTampered(String)
    case storage(String)

    public var description: String {
        switch self {
        case .passwordTooShort(let n): return "The accountability password must be at least \(n) characters."
        case .randomFailed: return "Could not generate random bytes."
        case .noAccountabilityPassword: return "Set an accountability password first."
        case .wrongPassword: return "Wrong accountability password."
        case .lockedOut(let r): return "Too many wrong attempts. Try again in \(Int(r.rounded(.up))) s."
        case .passwordChangeBlockedDuringSession: return "The accountability password can't be changed during a strict session."
        case .invalidDuration(let max): return "Duration must be between 1 minute and \(Int(max / 60)) minutes."
        case .unknownBlocklist(let n): return "No blocklist named \"\(n)\"."
        case .unknownSession(let id): return "No active session \(id)."
        case .unknownSchedule(let n): return "No schedule named \"\(n)\"."
        case .duplicateName(let n): return "\"\(n)\" already exists."
        case .timerLocked(let r): return "This session is timer-locked and can't be stopped. \(Self.format(r)) left."
        case .weakensActiveSession(let why): return "Not allowed during a strict session: \(why)."
        case .invalidRule(let r): return "Invalid rule \"\(r)\"."
        case .protectedApp(let id): return "\(id) is part of macOS or Focus Blocker and can't be blocked."
        case .invalidSchedule(let why): return "Invalid schedule: \(why)."
        case .stateTampered(let why): return "Saved state failed its integrity check: \(why)."
        case .storage(let why): return "Storage error: \(why)."
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
