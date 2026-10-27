import Foundation

extension ScheduleRule {
    /// Length of one occurrence in minutes. Equal start and end means a full 24 hours.
    public var durationMinutes: Int {
        let d = (endMinute - startMinute + 1440) % 1440
        return d == 0 ? 1440 : d
    }

    public func validate() throws {
        guard !weekdays.isEmpty, weekdays.allSatisfy({ (1...7).contains($0) }) else { throw FocusError.invalidSchedule("weekdays must be 1–7") }
        guard (0..<1440).contains(startMinute), (0..<1440).contains(endMinute) else { throw FocusError.invalidSchedule("times must be within a day") }
        guard TimeZone(identifier: timeZoneID) != nil else { throw FocusError.invalidSchedule("unknown time zone \(timeZoneID)") }
        guard !blocklistIDs.isEmpty else { throw FocusError.invalidSchedule("no blocklists") }
    }

    /// The occurrence covering `date`, if any. Checks the previous day too, for windows that run past midnight.
    public func activeWindow(at date: Date) -> DateInterval? {
        guard enabled, let tz = TimeZone(identifier: timeZoneID) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let today = cal.startOfDay(for: date)
        for dayOffset in [-1, 0] {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: today),
                  weekdays.contains(cal.component(.weekday, from: day)),
                  let start = cal.date(byAdding: .minute, value: startMinute, to: day),
                  let end = cal.date(byAdding: .minute, value: durationMinutes, to: start)
            else { continue }
            if start <= date && date < end { return DateInterval(start: start, end: end) }
        }
        return nil
    }

    /// True when `other` blocks at least as much time with at least the same strength.
    func isNoWeakerThan(_ old: ScheduleRule) -> Bool {
        guard old.enabled else { return true }
        return enabled
            && Set(blocklistIDs).isSuperset(of: old.blocklistIDs)
            && weekdays.isSuperset(of: old.weekdays)
            && startMinute == old.startMinute && endMinute == old.endMinute
            && timeZoneID == old.timeZoneID
            && lock.strength >= old.lock.strength
            && (strict || !old.strict)
    }
}

extension LockKind {
    /// Ordering used to decide whether an edit weakens a lock.
    var strength: Int {
        switch self {
        case .none: return 0
        case .password: return 1
        case .timer: return 2
        }
    }
}

public enum Weekday {
    static let names = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]

    /// Parses `mon,tue`, `weekdays`, `weekends` or `all`.
    public static func parse(_ text: String) throws -> Set<Int> {
        switch text.lowercased() {
        case "all", "daily": return Set(1...7)
        case "weekdays": return [2, 3, 4, 5, 6]
        case "weekends": return [1, 7]
        default:
            var days = Set<Int>()
            for part in text.lowercased().split(separator: ",") {
                guard let d = names[String(part.prefix(3))] else { throw FocusError.invalidSchedule("unknown day \"\(part)\"") }
                days.insert(d)
            }
            return days
        }
    }

    /// Parses `HH:MM` into minutes after midnight.
    public static func parseTime(_ text: String) throws -> Int {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else {
            throw FocusError.invalidSchedule("time \"\(text)\" must be HH:MM")
        }
        return parts[0] * 60 + parts[1]
    }
}
