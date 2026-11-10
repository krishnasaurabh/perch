import Foundation

/// The three outcomes of editing a standalone repeat field. This keeps an explicit clear distinct from invalid text.
public enum TaskRepeatParseResult: Equatable, Sendable {
    case invalid
    case clear
    case rule(TaskRepeat)
}

/// How a task repeats. When a repeating task is completed, the next copy is planned.
public struct TaskRepeat: Codable, Equatable, Sendable, CustomStringConvertible {
    public enum Unit: String, Codable, Sendable { case day, week, month }

    public var unit: Unit
    public var interval: Int
    /// Calendar weekdays (1 = Sunday ... 7 = Saturday). Only used with `.week`.
    public var weekdays: [Int]
    /// Monday to Friday only.
    public var weekdaysOnly: Bool
    /// `every!`: counted from the day the last copy was completed, not from its planned day.
    public var fromCompletion: Bool

    public init(
        unit: Unit, interval: Int = 1, weekdays: [Int] = [], weekdaysOnly: Bool = false, fromCompletion: Bool = false
    ) {
        self.unit = unit; self.interval = max(1, interval); self.weekdays = weekdays.sorted()
        self.weekdaysOnly = weekdaysOnly; self.fromCompletion = fromCompletion
    }

    public static let daily = TaskRepeat(unit: .day)
    public static let weekdaysRule = TaskRepeat(unit: .day, weekdaysOnly: true)
    public static let weekly = TaskRepeat(unit: .week)
    public static let monthly = TaskRepeat(unit: .month)

    static let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    public var description: String {
        let bang = fromCompletion ? "!" : ""
        if weekdaysOnly { return "every\(bang) weekday" }
        let every = interval == 1 ? "every\(bang) " : "every\(bang) \(interval) "
        switch unit {
        case .day: return interval == 1 ? "every\(bang) day" : "\(every)days"
        case .month: return interval == 1 ? "every\(bang) month" : "\(every)months"
        case .week:
            let base = interval == 1 ? "every\(bang) week" : "\(every)weeks"
            if weekdays.isEmpty { return base }
            let names = weekdays.map { TaskRepeat.dayNames[$0 - 1] }.joined(separator: ", ")
            return interval == 1 ? "every\(bang) \(names)" : "\(base) on \(names)"
        }
    }

    /// The day the next copy lands on.
    /// - Parameters:
    ///   - planned: the day the current copy was planned on.
    ///   - completed: the day it was completed (used for `every!`).
    public func next(after planned: DayKey, completed: DayKey, calendar: Calendar = .current) -> DayKey {
        let calendar = calendar.plannerStorage
        let base = fromCompletion ? completed : planned
        if weekdaysOnly {
            var d = base.adding(days: 1, calendar: calendar)
            while [1, 7].contains(d.weekday(calendar: calendar)) { d = d.adding(days: 1, calendar: calendar) }
            return d
        }
        switch unit {
        case .day:
            return base.adding(days: interval, calendar: calendar)
        case .month:
            let date = calendar.date(byAdding: .month, value: interval, to: base.date(calendar: calendar))!
            return DayKey(date, calendar: calendar)
        case .week:
            guard !weekdays.isEmpty else { return base.adding(days: 7 * interval, calendar: calendar) }
            // Next listed weekday in the same week; otherwise first listed weekday `interval` weeks on.
            let wd = base.weekday(calendar: calendar)
            if let later = weekdays.first(where: { $0 > wd }) {
                return base.adding(days: later - wd, calendar: calendar)
            }
            let startOfWeek = base.adding(days: -(wd - 1), calendar: calendar)
            return startOfWeek.adding(days: 7 * interval + (weekdays[0] - 1), calendar: calendar)
        }
    }

    /// The first day on or after `day` this rule can land on (for weekday lists and weekdays-only).
    public func firstOccurrence(onOrAfter day: DayKey, calendar: Calendar = .current) -> DayKey {
        var d = day
        for _ in 0..<7 {
            let wd = d.weekday(calendar: calendar)
            if weekdaysOnly ? ![1, 7].contains(wd) : (unit != .week || weekdays.isEmpty || weekdays.contains(wd)) {
                return d
            }
            d = d.adding(days: 1, calendar: calendar)
        }
        return day
    }

    // MARK: Parsing

    static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "other": 2,
    ]

    static let weekdayAlt =
        "sunday|monday|tuesday|wednesday|thursday|friday|saturday|tues|thurs|thur|sun|mon|tue|wed|thu|fri|sat"
    static let weekdayListPattern =
        "(?:\(weekdayAlt))s?\\b(?:(?:\\s*,\\s*(?:and\\s+)?|\\s*&\\s*|\\s+and\\s+)(?:\(weekdayAlt))s?\\b)*"

    /// Matches explicit repeat phrases in free text ("every 3 weeks on mon, thu", "every! 4 days").
    static let pattern = try! NSRegularExpression(
        pattern:
            "\\b(?:every(?<bang>!)?\\s+(?:(?<count>other|\\d{1,3}|two|three|four|five|six|seven|eight|nine|ten)\\s+)?"
            + "(?:(?<unit>day|month)s?\\b|(?<week>week)s?\\b(?:\\s+on\\s+(?<on>\(weekdayListPattern)))?"
            + "|(?<weekday>weekday)s?\\b|(?<list>\(weekdayListPattern)))"
            + ")",
        options: [.caseInsensitive])

    /// Parses a standalone rule like `daily`, `every mon, wed`, or an explicit clear such as `none`.
    public static func parseRule(_ text: String) -> TaskRepeatParseResult {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t == "none" || t == "never" || t.isEmpty { return .clear }
        // Aliases are unambiguous in a dedicated repeat field, not in a task title.
        switch t {
        case "daily": return .rule(.daily)
        case "weekly": return .rule(.weekly)
        case "monthly": return .rule(.monthly)
        case "weekdays": return .rule(.weekdaysRule)
        default: break
        }
        guard let (rule, range) = find(in: t), range.location == 0, range.length == (t as NSString).length else {
            return .invalid
        }
        return .rule(rule)
    }

    /// Finds the first repeat phrase in `text`, returning the rule and the matched range.
    public static func find(in text: String) -> (TaskRepeat, NSRange)? {
        let ns = text as NSString
        guard let m = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func g(_ name: String) -> String? {
            let r = m.range(withName: name)
            return r.location == NSNotFound ? nil : ns.substring(with: r).lowercased()
        }
        let bang = g("bang") != nil
        var count = 1
        if let c = g("count") { count = Int(c) ?? numberWords[c] ?? 1 }
        if g("weekday") != nil { return (TaskRepeat(unit: .day, weekdaysOnly: true, fromCompletion: bang), m.range) }
        if let unit = g("unit") {
            return (TaskRepeat(unit: unit == "day" ? .day : .month, interval: count, fromCompletion: bang), m.range)
        }
        if g("week") != nil {
            let days = g("on").map(weekdays(in:)) ?? []
            return (TaskRepeat(unit: .week, interval: count, weekdays: days, fromCompletion: bang), m.range)
        }
        if let list = g("list") {
            return (
                TaskRepeat(unit: .week, interval: count, weekdays: weekdays(in: list), fromCompletion: bang), m.range
            )
        }
        return nil
    }

    static func weekdays(in list: String) -> [Int] {
        let re = try! NSRegularExpression(pattern: "\(weekdayAlt)", options: .caseInsensitive)
        let ns = list as NSString
        var out = Set<Int>()
        for m in re.matches(in: list, range: NSRange(location: 0, length: ns.length)) {
            if let i = weekdayIndex(ns.substring(with: m.range)) { out.insert(i) }
        }
        return out.sorted()
    }

    /// 1 = Sunday ... 7 = Saturday.
    static func weekdayIndex(_ s: String) -> Int? {
        let p = String(s.lowercased().prefix(3))
        return dayNames.firstIndex(of: p).map { $0 + 1 }
    }
}
