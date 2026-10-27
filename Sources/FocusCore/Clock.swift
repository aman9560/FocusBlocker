import Foundation

/// Abstracts time so the engine can be tested and so wall time is never trusted alone.
public protocol ClockSource {
    func wallNow() -> Date
    /// Seconds since boot, including sleep. Unaffected by changes to the system clock.
    func monotonicNow() -> TimeInterval
    /// Changes on every reboot.
    func bootID() -> String
}

public struct SystemClock: ClockSource {
    public init() {}

    public func wallNow() -> Date { Date() }

    public func monotonicNow() -> TimeInterval {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom)
        return nanos / 1_000_000_000
    }

    public func bootID() -> String {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return "unknown" }
        return "\(boot.tv_sec).\(boot.tv_usec)"
    }
}

public struct ClockAnchor: Codable, Equatable, Sendable {
    public var bootID: String
    public var wall: Date
    public var monotonic: TimeInterval
}

public enum ClockAnomaly: Codable, Equatable, Sendable {
    case wallJumpedForward(seconds: TimeInterval)
    case wallJumpedBackward(seconds: TimeInterval)
    case wallBehindAfterReboot(seconds: TimeInterval)
}

/// Decides how much focus time has really passed since the last tick.
///
/// Within one boot only monotonic time counts, so changing the clock cannot shorten a session.
/// Across a reboot there is no monotonic link, so wall time counts, but never negatively.
public enum TimeAccountant {
    /// Differences between wall and monotonic time smaller than this are ordinary drift or NTP slew.
    public static let tolerance: TimeInterval = 5

    public static func advance(from anchor: ClockAnchor?, clock: ClockSource) -> (elapsed: TimeInterval, anomaly: ClockAnomaly?, anchor: ClockAnchor) {
        let now = ClockAnchor(bootID: clock.bootID(), wall: clock.wallNow(), monotonic: clock.monotonicNow())
        guard let anchor else { return (0, nil, now) }

        let wallDelta = now.wall.timeIntervalSince(anchor.wall)
        if anchor.bootID == now.bootID {
            let monoDelta = max(0, now.monotonic - anchor.monotonic)
            let skew = wallDelta - monoDelta
            var anomaly: ClockAnomaly?
            if skew > tolerance {
                anomaly = .wallJumpedForward(seconds: skew)
            } else if skew < -tolerance {
                anomaly = .wallJumpedBackward(seconds: -skew)
            }
            return (monoDelta, anomaly, now)
        }

        if wallDelta < -tolerance {
            return (0, .wallBehindAfterReboot(seconds: -wallDelta), now)
        }
        return (max(0, wallDelta), nil, now)
    }
}
