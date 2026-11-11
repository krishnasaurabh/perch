import Foundation
import PlannerCore

/// An editable day value that never writes to the planner. Views hold one, edit it,
/// and hand the result of `commit()` to the caller, which turns it into a typed action.
public struct DateFieldDraft: Equatable, Sendable {
    public enum Requirement: Equatable, Sendable { case optional, required }

    /// How days before `today` are treated. Validation reports; it never moves the value.
    public enum PastDayPolicy: Equatable, Sendable {
        case allow
        /// Show a warning but accept the day.
        case warn
        /// Block a newly chosen past day. An unchanged past original is still accepted.
        case reject
    }

    public enum Entry: Equatable, Sendable {
        case none
        case day(DayKey)
        /// Text the user typed that is not a valid day. Kept verbatim so it can be corrected.
        case invalid(String)
    }

    public enum Issue: Equatable, Sendable {
        public enum Severity: Equatable, Sendable { case warning, error }
        case required
        case unparseable(String)
        case pastDay(DayKey)
        case pastDayNotAllowed(DayKey)

        public var severity: Severity {
            switch self {
            case .pastDay: .warning
            case .required, .unparseable, .pastDayNotAllowed: .error
            }
        }

        public var message: String {
            switch self {
            case .required: "Choose a date."
            case .unparseable(let text): "“\(text)” is not a date. Use YYYY-MM-DD."
            case .pastDay: "This day has already passed."
            case .pastDayNotAllowed: "Choose today or a later day."
            }
        }
    }

    /// The outcome handed to the caller. `nil` from `commit()` means the draft is invalid.
    public enum Commit: Equatable, Sendable {
        case unchanged
        case set(DayKey)
        case cleared

        /// The edit expressed in the planner's typed change vocabulary.
        public var change: FieldChange<DayKey?> {
            switch self {
            case .unchanged: .keep
            case .set(let day): .set(day)
            case .cleared: .set(nil)
            }
        }
    }

    public let original: DayKey?
    public let today: DayKey
    public let requirement: Requirement
    public let pastDays: PastDayPolicy
    public private(set) var entry: Entry
    /// The text shown in the typed-entry field.
    public private(set) var text: String
    /// Set once the user edits or a commit is attempted.
    /// Required/no-selection errors remain visible even before an attempt.
    public private(set) var attempted = false
    private var lastValidDay: DayKey?

    public init(
        original: DayKey?, today: DayKey, requirement: Requirement = .optional, pastDays: PastDayPolicy = .warn
    ) {
        self.original = original
        self.today = today
        self.requirement = requirement
        self.pastDays = pastDays
        entry = original.map(Entry.day) ?? Entry.none
        text = original?.raw ?? ""
        lastValidDay = original
    }

    // MARK: Editing

    /// A day chosen with the graphical picker. The civil day in `calendar` is kept.
    public mutating func select(_ date: Date, calendar: Calendar = .current) {
        setDay(DayKey(date, calendar: calendar))
    }

    /// Text typed into the entry field. Empty text means no date.
    public mutating func type(_ input: String) {
        attempted = true
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        text = input
        if trimmed.isEmpty {
            entry = .none
        } else if let day = DayKey(trimmed) {
            entry = .day(day)
            lastValidDay = day
        } else {
            entry = .invalid(trimmed)
        }
    }

    public mutating func clear() {
        attempted = true
        entry = .none
        text = ""
    }

    /// Leave the none state with a sensible starting day: the original, else today.
    public mutating func addSuggested() {
        setDay(original ?? today)
        if original != nil { attempted = false }
    }

    /// Discard every edit and any failed commit attempt.
    public mutating func revert() {
        self = DateFieldDraft(original: original, today: today, requirement: requirement, pastDays: pastDays)
    }

    /// The validated result, or `nil` while the draft is invalid. A failed attempt reveals the issue inline.
    public mutating func commit() -> Commit? {
        attempted = true
        guard canCommit else { return nil }
        switch entry {
        case .day(let day): return day == original ? .unchanged : .set(day)
        case .none: return original == nil ? .unchanged : .cleared
        case .invalid: return nil
        }
    }

    private mutating func setDay(_ day: DayKey) {
        attempted = true
        entry = .day(day)
        text = day.raw
        lastValidDay = day
    }

    // MARK: Reading

    public var hasChanges: Bool {
        switch entry {
        case .day(let day): day != original
        case .none: original != nil
        case .invalid: true
        }
    }

    public var issue: Issue? {
        switch entry {
        case .invalid(let text): return .unparseable(text)
        case .none: return requirement == .required ? .required : nil
        case .day(let day):
            guard day < today else { return nil }
            switch pastDays {
            case .allow: return nil
            case .warn: return .pastDay(day)
            case .reject: return day == original ? .pastDay(day) : .pastDayNotAllowed(day)
            }
        }
    }

    /// The issue to show beside the field right now.
    public var visibleIssue: Issue? {
        guard let issue else { return nil }
        // Explain an empty required field even before editing: Apply is already disabled.
        if case .required = issue { return issue }
        // Past-day notes describe the stored value, so they are shown from the start.
        if case .pastDay = issue { return issue }
        return attempted ? issue : nil
    }

    public var canCommit: Bool { issue?.severity != .error }

    /// The date the graphical picker shows. Invalid text leaves it on the last valid day.
    public func pickerDate(calendar: Calendar = .current) -> Date {
        let day: DayKey
        switch entry {
        case .day(let value): day = value
        case .none, .invalid: day = lastValidDay ?? original ?? today
        }
        // Noon avoids a picker landing on a neighbouring day across DST or zone changes.
        let start = day.date(calendar: calendar)
        return calendar.date(byAdding: .hour, value: 12, to: start) ?? start
    }

    public func accessibilityValue(calendar: Calendar = .current, locale: Locale = .current) -> String {
        switch entry {
        case .none: return "No date"
        case .invalid(let text): return "Not a date: \(text)"
        case .day(let day):
            var style = Date.FormatStyle(date: .complete, time: .omitted, locale: locale, calendar: calendar)
            style.timeZone = calendar.timeZone
            return pickerDate(calendar: calendar).formatted(style)
        }
    }
}

/// Controls in a date editor, in keyboard order, with stable labels and identifiers.
public enum DateFieldControl: String, CaseIterable, Sendable {
    case add, text, picker, clear, cancel, commit

    /// Tab order while a date is being edited. `add` replaces `text` and `picker` in the none state.
    public static let focusOrder: [DateFieldControl] = [.text, .picker, .clear, .cancel, .commit]

    public func accessibilityLabel(field: String) -> String {
        let lower = field.lowercased()
        switch self {
        case .add: return "Add \(lower)"
        case .text: return "\(field), typed date"
        case .picker: return field
        case .clear: return "Clear \(lower)"
        case .cancel: return "Cancel \(lower) edit"
        case .commit: return "Apply \(lower)"
        }
    }

    public func identifier(field: String) -> String { "\(field)-date-\(rawValue)" }
}
