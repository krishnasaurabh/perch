import Foundation
import PlannerCore

/// An editable copy of a task's repeat rule. It never writes to a planner: `commit()` returns a
/// value the owner turns into a typed `PlannerAction`, and `revert()` discards every edit.
public struct RepeatPickerDraft: Equatable, Sendable {
    /// Choices offered by the picker. Each maps onto a rule `TaskRepeat` already supports.
    public enum Frequency: String, CaseIterable, Sendable {
        case none, daily, weekdays, weekly, monthly, quarterly, yearly, custom

        public var title: String {
            switch self {
            case .none: PerchL10n.text("Does not repeat")
            case .daily: PerchL10n.text("Daily")
            case .weekdays: PerchL10n.text("Weekdays")
            case .weekly: PerchL10n.text("Weekly")
            case .monthly: PerchL10n.text("Monthly")
            case .quarterly: PerchL10n.text("Quarterly")
            case .yearly: PerchL10n.text("Yearly")
            case .custom: PerchL10n.text("Custom")
            }
        }
    }

    public enum CustomUnit: String, CaseIterable, Sendable {
        case day, week, month

        public func title(plural: Bool) -> String {
            switch (self, plural) {
            case (.day, false): PerchL10n.text("day")
            case (.day, true): PerchL10n.text("days")
            case (.week, false): PerchL10n.text("week")
            case (.week, true): PerchL10n.text("weeks")
            case (.month, false): PerchL10n.text("month")
            case (.month, true): PerchL10n.text("months")
            }
        }

        var unit: TaskRepeat.Unit {
            switch self {
            case .day: .day
            case .week: .week
            case .month: .month
            }
        }
    }

    /// The control an issue belongs to, so the view can place the message and move focus there.
    public enum Field: Hashable, Sendable { case frequency, interval }

    public enum Issue: Equatable, Sendable {
        case invalidInterval(String)
        case missingAnchor

        public var field: Field {
            switch self {
            case .invalidInterval: .interval
            case .missingAnchor: .frequency
            }
        }

        public var message: String {
            switch self {
            case .invalidInterval(let text):
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.isEmpty {
                    return PerchL10n.format(
                        "Enter how often it repeats, from 1 to %lld.", RepeatPickerDraft.maximumInterval)
                }
                return PerchL10n.format(
                    "“%@” is not a valid interval. Enter a whole number from 1 to %lld.",
                    clean, RepeatPickerDraft.maximumInterval)
            case .missingAnchor:
                return PerchL10n.text("Choose a date for this task before setting a repeat.")
            }
        }
    }

    /// The result of a successful commit, ready to become a typed planner action.
    public enum Commit: Equatable, Sendable {
        case unchanged
        case cleared
        case set(TaskRepeat)

        /// The repeat field of `TaskEdit`; `nil` leaves the field alone.
        public var transportText: String? {
            switch self {
            case .unchanged: nil
            case .cleared: "none"
            case .set(let rule): rule.description
            }
        }

        public func apply(to edit: inout TaskEdit) {
            if let text = transportText { edit.repeatRule = text }
        }

        /// A standalone action for this change. Clearing ends the series and keeps planned copies.
        public func action(taskID: UUID) -> PlannerAction? {
            switch self {
            case .unchanged: return nil
            case .cleared: return .endRepeat(taskID)
            case .set:
                var edit = TaskEdit()
                apply(to: &edit)
                return .update(taskID, edit)
            }
        }
    }

    /// Upcoming days, computed from the task's date in the planner's calendar.
    public enum Preview: Equatable, Sendable {
        case none
        /// The draft is invalid or has no date to count from.
        case unavailable
        case scheduled([DayKey])
        /// Completion-relative rules have no schedule; show one worked example instead.
        case afterCompletion(completed: DayKey, next: DayKey)
    }

    public static let maximumInterval = 999
    public static let weekdayNames = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
    ]
    public static let weekdayShortNames = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

    public let original: TaskRepeat?
    /// The current or edited occurrence day, owned by the date field. A repeat needs a date.
    public private(set) var anchor: DayKey?
    /// The existing series start, which stays fixed when only the occurrence day changes.
    public let seriesAnchor: DayKey?
    public private(set) var frequency: Frequency
    public private(set) var customUnit: CustomUnit
    /// Kept as typed so an invalid entry is shown back to the person, not silently replaced.
    public private(set) var intervalText: String
    /// Calendar weekdays (1 = Sunday ... 7 = Saturday) used by weekly rules.
    public private(set) var weekdays: [Int]
    public private(set) var fromCompletion: Bool
    public private(set) var attemptedCommit = false
    /// Rule edits and date changes are tracked apart: a new date never rewrites a kept rule.
    private var ruleTouched = false
    private var anchorTouched = false
    private let calendar: Calendar

    /// Supply both dates for an existing occurrence, or use `init(task:calendar:)`.
    /// Without an explicit series anchor, an existing rule starts at the initial occurrence day.
    public init(
        original: TaskRepeat?, anchor: DayKey?, seriesAnchor: DayKey? = nil, calendar: Calendar = .current
    ) {
        self.original = original
        self.anchor = anchor
        self.seriesAnchor = original == nil ? nil : (seriesAnchor ?? anchor)
        self.calendar = Self.storageCalendar(calendar)
        fromCompletion = original?.fromCompletion ?? false
        weekdays = original.map { $0.unit == .week ? $0.weekdays : [] } ?? []
        customUnit = .day
        intervalText = "2"
        frequency = .none
        guard let original else { return }
        if original.weekdaysOnly {
            frequency = .weekdays
            return
        }
        customUnit = Self.customUnit(for: original.unit)
        intervalText = String(original.interval)
        switch (original.unit, original.interval) {
        case (.day, 1): frequency = .daily
        case (.week, 1): frequency = .weekly
        case (.month, 1): frequency = .monthly
        case (.month, 3): frequency = .quarterly
        case (.month, 12): frequency = .yearly
        default: frequency = .custom
        }
    }

    public init(task: PlanTask, calendar: Calendar = .current) {
        self.init(
            original: task.repeatRule, anchor: task.day, seriesAnchor: task.repeatAnchor, calendar: calendar)
    }

    // MARK: Editing

    public mutating func select(_ next: Frequency) {
        ruleTouched = true
        if next == .custom, frequency != .custom {
            // Start from the current cadence; a single-step preset suggests "every 2".
            if let current = rule, !current.weekdaysOnly {
                customUnit = Self.customUnit(for: current.unit)
                intervalText = String(current.interval == 1 ? 2 : current.interval)
            } else {
                customUnit = .day
                intervalText = "2"
            }
        }
        frequency = next
    }

    public mutating func setCustomUnit(_ unit: CustomUnit) {
        ruleTouched = true
        customUnit = unit
    }

    public mutating func typeInterval(_ text: String) {
        ruleTouched = true
        intervalText = text
    }

    /// Stepper input. Invalid text recovers to the nearest valid value instead of staying stuck.
    public mutating func stepInterval(by step: Int) {
        ruleTouched = true
        let current = parsedInterval ?? 1 - step
        intervalText = String(min(max(current + step, 1), Self.maximumInterval))
    }

    public mutating func toggleWeekday(_ weekday: Int) {
        guard (1...7).contains(weekday) else { return }
        ruleTouched = true
        if let i = weekdays.firstIndex(of: weekday) {
            weekdays.remove(at: i)
        } else {
            weekdays = (weekdays + [weekday]).sorted()
        }
    }

    public mutating func setFromCompletion(_ value: Bool) {
        ruleTouched = true
        fromCompletion = value
    }

    /// Update the occurrence day without moving the preserved series start.
    public mutating func setAnchor(_ day: DayKey?) {
        guard day != anchor else { return }
        anchorTouched = true
        anchor = day
    }

    /// Cancel: forget every edit and failed commit, keeping the date supplied by its own field.
    public mutating func revert() {
        self = RepeatPickerDraft(original: original, anchor: anchor, seriesAnchor: seriesAnchor, calendar: calendar)
    }

    // MARK: State

    public var parsedInterval: Int? {
        let clean = intervalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.allSatisfy(\.isASCII), clean.allSatisfy(\.isNumber), let value = Int(clean),
            (1...Self.maximumInterval).contains(value)
        else { return nil }
        return value
    }

    /// The rule the current choices describe, or `nil` for "does not repeat" and invalid input.
    public var rule: TaskRepeat? {
        let unit: TaskRepeat.Unit
        let interval: Int
        switch frequency {
        case .none: return nil
        case .weekdays: return TaskRepeat(unit: .day, weekdaysOnly: true, fromCompletion: fromCompletion)
        case .daily: (unit, interval) = (.day, 1)
        case .weekly: (unit, interval) = (.week, 1)
        case .monthly: (unit, interval) = (.month, 1)
        case .quarterly: (unit, interval) = (.month, 3)
        case .yearly: (unit, interval) = (.month, 12)
        case .custom:
            guard let value = parsedInterval else { return nil }
            (unit, interval) = (customUnit.unit, value)
        }
        return TaskRepeat(
            unit: unit, interval: interval, weekdays: unit == .week ? weekdays : [], fromCompletion: fromCompletion)
    }

    public var issue: Issue? {
        guard frequency != .none else { return nil }
        if ruleTouched, frequency == .custom, parsedInterval == nil { return .invalidInterval(intervalText) }
        if anchor == nil { return .missingAnchor }
        return nil
    }

    /// Opening the editor on stored data is not an edit, so it does not open with an error.
    public var visibleIssue: Issue? { ruleTouched || anchorTouched || attemptedCommit ? issue : nil }

    public var hasChanges: Bool {
        // An untouched draft keeps the stored rule, even one these controls cannot express.
        guard ruleTouched else { return false }
        if frequency == .custom, parsedInterval == nil { return true }
        // Descriptions are the storage form, so equal descriptions are the same schedule.
        return rule?.description != original?.description
    }

    /// Returns `nil` and reveals the inline error when an edit is invalid.
    public mutating func commit() -> Commit? {
        if ruleTouched || anchorTouched, issue != nil {
            attemptedCommit = true
            return nil
        }
        guard hasChanges else { return .unchanged }
        guard let rule else { return .cleared }
        return .set(rule)
    }

    // MARK: Presentation

    public var summary: String { summary(locale: .current) }

    public func summary(locale: Locale) -> String {
        guard frequency != .none else { return Frequency.none.title }
        guard let rule else { return PerchL10n.text("Custom repeat", locale: locale) }
        let suffix = rule.fromCompletion ? PerchL10n.text(" after completion", locale: locale) : ""
        if rule.weekdaysOnly { return PerchL10n.text("Every weekday", locale: locale) + suffix }
        let n = rule.interval
        switch rule.unit {
        case .day:
            return PerchL10n.format("%lld day repeat", locale: locale, n) + suffix
        case .month:
            if n == 12 { return PerchL10n.text("Every year", locale: locale) + suffix }
            return PerchL10n.format("%lld month repeat", locale: locale, n) + suffix
        case .week:
            var text = PerchL10n.format("%lld week repeat", locale: locale, n)
            let days =
                rule.weekdays.isEmpty ? scheduleAnchor.map { [$0.weekday(calendar: calendar)] } ?? [] : rule.weekdays
            if !days.isEmpty {
                let names = Self.localizedWeekdayNames(locale: locale)
                text +=
                    PerchL10n.text(" on ", locale: locale)
                    + days.map { names[$0 - 1] }.joined(separator: PerchL10n.text(", ", locale: locale))
            }
            return text + suffix
        }
    }

    public static func localizedWeekdayNames(locale: Locale = .current) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        #if os(macOS)
            return formatter.standaloneWeekdaySymbols ?? weekdayNames
        #else
            return formatter.standaloneWeekdaySymbols
        #endif
    }

    public static func localizedShortWeekdayNames(locale: Locale = .current) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        #if os(macOS)
            return formatter.veryShortStandaloneWeekdaySymbols ?? weekdayShortNames
        #else
            return formatter.veryShortStandaloneWeekdaySymbols
        #endif
    }

    /// The next `count` days a scheduled rule lands on after the task's own day.
    public func preview(count: Int = 3) -> Preview {
        guard frequency != .none else { return .none }
        guard issue == nil, let rule = hasChanges ? rule : original, let anchor, count > 0 else {
            return .unavailable
        }
        if rule.fromCompletion {
            return .afterCompletion(
                completed: anchor, next: rule.next(after: anchor, completed: anchor, calendar: calendar))
        }
        guard let start = scheduleAnchor else { return .unavailable }
        return .scheduled(Self.upcoming(rule, starting: start, after: anchor, count: count, calendar: calendar))
    }

    /// Readable preview text. Days are formatted as civil dates, independent of the process time zone.
    public static func previewText(_ preview: Preview, anchor: DayKey?, locale: Locale = .current) -> String? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func format(_ day: DayKey) -> String {
            let sameYear = anchor.map { $0.raw.prefix(4) == day.raw.prefix(4) } ?? true
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = utc
            formatter.timeZone = utc.timeZone
            formatter.setLocalizedDateFormatFromTemplate(sameYear ? "EEE MMM d" : "EEE MMM d y")
            return formatter.string(from: day.date(calendar: utc))
        }
        switch preview {
        case .none, .unavailable: return nil
        case .scheduled(let days):
            guard !days.isEmpty else { return nil }
            return PerchL10n.text("Next: ", locale: locale)
                + days.map(format).joined(separator: PerchL10n.text(" · ", locale: locale))
        case let .afterCompletion(completed, next):
            return PerchL10n.format(
                "If completed %@, next is %@", locale: locale, format(completed), format(next))
        }
    }

    // MARK: Schedule arithmetic

    /// A changed cadence starts a new series on the edited day, just like a typed task update.
    /// Merely visiting another frequency and returning to the original cadence keeps the series.
    private var scheduleAnchor: DayKey? { hasChanges ? anchor : (seriesAnchor ?? anchor) }

    private static func customUnit(for unit: TaskRepeat.Unit) -> CustomUnit {
        switch unit {
        case .day: .day
        case .week: .week
        case .month: .month
        }
    }

    /// Counted from the anchor, as planned copies are, so month-end clamping does not drift.
    private static func upcoming(
        _ rule: TaskRepeat, starting anchor: DayKey, after occurrence: DayKey, count: Int, calendar: Calendar
    ) -> [DayKey] {
        let after = max(anchor, occurrence)
        var out: [DayKey] = []
        if rule.weekdaysOnly {
            var day = after
            while out.count < count {
                day = day.adding(days: 1, calendar: calendar)
                if ![1, 7].contains(day.weekday(calendar: calendar)) { out.append(day) }
            }
            return out
        }
        let interval = max(1, rule.interval)
        switch rule.unit {
        case .day, .week:
            if rule.unit == .day || rule.weekdays.isEmpty {
                let stride = rule.unit == .day ? interval : interval * 7
                let elapsed = calendar.dateComponents(
                    [.day], from: anchor.date(calendar: calendar), to: after.date(calendar: calendar)
                ).day!
                let first = elapsed / stride + 1
                return (first..<(first + count)).map { anchor.adding(days: $0 * stride, calendar: calendar) }
            }
            let weekStart = anchor.adding(days: -(anchor.weekday(calendar: calendar) - 1), calendar: calendar)
            let elapsed = calendar.dateComponents(
                [.day], from: weekStart.date(calendar: calendar), to: after.date(calendar: calendar)
            ).day!
            var cycle = elapsed / (interval * 7)
            while out.count < count {
                for weekday in rule.weekdays where out.count < count {
                    let day = weekStart.adding(days: cycle * interval * 7 + weekday - 1, calendar: calendar)
                    if day > after { out.append(day) }
                }
                cycle += 1
            }
            return out
        case .month:
            let start = anchor.date(calendar: calendar)
            let a = calendar.dateComponents([.year, .month], from: start)
            let b = calendar.dateComponents([.year, .month], from: after.date(calendar: calendar))
            let elapsed = (b.year! - a.year!) * 12 + b.month! - a.month!
            var cycle = max(1, elapsed / interval)
            while out.count < count {
                let day = DayKey(
                    calendar.date(byAdding: .month, value: cycle * interval, to: start)!, calendar: calendar)
                if day > after { out.append(day) }
                cycle += 1
            }
            return out
        }
    }

    /// Day arithmetic matches planner storage: Gregorian in the caller's time zone, whatever
    /// calendar the person displays.
    private static func storageCalendar(_ calendar: Calendar) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = calendar.timeZone
        value.firstWeekday = calendar.firstWeekday
        value.minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek
        return value
    }
}

/// Fixed metrics for the repeat picker, so it fits tiny windows without truncating controls.
public enum RepeatPickerLayout {
    public static let weekdayTarget: Double = ThemeTokens.minimumTarget
    public static let weekdaySpacing: Double = 4
    /// Seven weekday targets in one row: the narrowest width the picker needs. Wider rows
    /// (interval and unit, Cancel and Done) stack vertically below their natural width.
    public static let compactMinimumWidth: Double = 7 * weekdayTarget + 6 * weekdaySpacing
    public static let intervalFieldWidth: Double = 48
}
