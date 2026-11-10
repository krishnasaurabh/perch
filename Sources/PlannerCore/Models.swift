import Foundation

public enum TaskPriority: String, Codable, CaseIterable, Sendable, Comparable {
    case none, low, medium, high

    var rank: Int { [.none: 0, .low: 1, .medium: 2, .high: 3][self]! }
    public static func < (a: TaskPriority, b: TaskPriority) -> Bool { a.rank < b.rank }
}

public struct Subtask: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var done: Bool
    public init(id: UUID = UUID(), title: String, done: Bool = false) {
        self.id = id; self.title = title; self.done = done
    }
}

public struct TaskProject: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    public init(id: UUID = UUID(), name: String, colorHex: String = "#8E8CF5") {
        self.id = id; self.name = name; self.colorHex = colorHex
    }
}

/// One task. A task lives either on a day (`day != nil`) or in the Inbox (`day == nil`).
public struct PlanTask: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    /// Gregorian yyyy-MM-dd in the local time zone, nil = Inbox.
    public var day: DayKey?
    public var done: Bool
    public var completedAt: Date?
    public var createdAt: Date
    public var remindAt: Date?
    public var deadline: DayKey?
    public var priority: TaskPriority
    public var projectID: UUID?
    public var notes: String
    public var repeatRule: TaskRepeat?
    /// Time limit for focus, in minutes.
    public var minutes: Int?
    public var steps: [Subtask]
    /// Focus seconds accumulated on this task.
    public var focusedSeconds: Double
    /// Set when the task was carried forward from an earlier day.
    public var carriedFrom: DayKey?
    /// Linked EKReminder calendarItemIdentifier when Reminders sync is on.
    public var reminderLink: String?
    /// Series-generation identity; initially the root task ID, fresh after a cadence edit.
    public var repeatedFrom: UUID?
    /// Scheduled phase, retained when individual occurrences move or are deleted.
    public var repeatAnchor: DayKey?
    public var carryCount: Int
    /// MCP clientInfo.name, never a caller-supplied tool argument.
    public var agentID: String?

    public var repeatSeriesID: UUID { repeatedFrom ?? id }

    public init(
        id: UUID = UUID(), title: String, day: DayKey?, done: Bool = false, completedAt: Date? = nil,
        createdAt: Date = Date(), remindAt: Date? = nil, deadline: DayKey? = nil,
        priority: TaskPriority = .none, projectID: UUID? = nil, notes: String = "",
        repeatRule: TaskRepeat? = nil, minutes: Int? = nil, steps: [Subtask] = [],
        focusedSeconds: Double = 0, carriedFrom: DayKey? = nil, reminderLink: String? = nil,
        repeatedFrom: UUID? = nil, carryCount: Int = 0, agentID: String? = nil, repeatAnchor: DayKey? = nil
    ) {
        self.id = id; self.title = title; self.day = day; self.done = done
        self.completedAt = completedAt; self.createdAt = createdAt; self.remindAt = remindAt
        self.deadline = deadline; self.priority = priority; self.projectID = projectID
        self.notes = notes; self.repeatRule = repeatRule; self.minutes = minutes; self.steps = steps
        self.focusedSeconds = focusedSeconds; self.carriedFrom = carriedFrom; self.reminderLink = reminderLink
        self.repeatedFrom = repeatedFrom; self.carryCount = carryCount; self.agentID = agentID
        self.repeatAnchor = repeatAnchor ?? (repeatRule == nil ? nil : day)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        day = try c.decodeIfPresent(DayKey.self, forKey: .day)
        done = try c.decodeMissing(Bool.self, forKey: .done, default: false)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        remindAt = try c.decodeIfPresent(Date.self, forKey: .remindAt)
        deadline = try c.decodeIfPresent(DayKey.self, forKey: .deadline)
        priority = try c.decodeMissing(TaskPriority.self, forKey: .priority, default: .none)
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        notes = try c.decodeMissing(String.self, forKey: .notes, default: "")
        repeatRule = try c.decodeIfPresent(TaskRepeat.self, forKey: .repeatRule)
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes)
        steps = try c.decodeMissing([Subtask].self, forKey: .steps, default: [])
        focusedSeconds = try c.decodeMissing(Double.self, forKey: .focusedSeconds, default: 0)
        carriedFrom = try c.decodeIfPresent(DayKey.self, forKey: .carriedFrom)
        reminderLink = try c.decodeIfPresent(String.self, forKey: .reminderLink)
        repeatedFrom = try c.decodeIfPresent(UUID.self, forKey: .repeatedFrom)
        repeatAnchor = try c.decodeIfPresent(DayKey.self, forKey: .repeatAnchor)
        carryCount = try c.decodeMissing(Int.self, forKey: .carryCount, default: 0)
        agentID = try c.decodeIfPresent(String.self, forKey: .agentID)
    }

    public var isInbox: Bool { day == nil }
}

/// A calendar day, stored as yyyy-MM-dd. Comparable lexicographically.
public struct DayKey: Codable, Hashable, Comparable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let raw: String
    public init?(_ raw: String) {
        guard DayKey.parse(raw) != nil else { return nil }
        self.raw = raw
    }
    public init(stringLiteral value: String) {
        precondition(DayKey.parse(value) != nil, "Invalid Gregorian day literal")
        self.raw = value
    }
    public init(_ date: Date, resetHour: Int = 0, calendar: Calendar = .current) {
        let calendar = calendar.plannerStorage
        let boundary = DayKey.wallTime(on: date, hour: min(23, max(0, resetHour)), calendar: calendar)
        let logicalDate = date < boundary ? calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: date))! : date
        let c = calendar.dateComponents([.year, .month, .day], from: logicalDate)
        raw = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let value = try c.decode(String.self)
        guard DayKey.parse(value) != nil else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Expected a valid Gregorian yyyy-MM-dd day.")
        }
        raw = value
    }
    public func encode(to encoder: Encoder) throws {
        guard DayKey.parse(raw) != nil else {
            throw EncodingError.invalidValue(raw, .init(codingPath: encoder.codingPath, debugDescription: "Invalid Gregorian day."))
        }
        var c = encoder.singleValueContainer(); try c.encode(raw)
    }
    public var description: String { raw }
    public static func < (a: DayKey, b: DayKey) -> Bool { a.raw < b.raw }

    static func parse(_ s: String) -> DateComponents? {
        let p = s.split(separator: "-")
        guard p.count == 3, p[0].count == 4, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
              (1...9999).contains(y), (1...12).contains(m), (1...31).contains(d),
              s == String(format: "%04d-%02d-%02d", y, m, d) else { return nil }
        let components = DateComponents(year: y, month: m, day: d)
        // Calendar normalizes impossible dates. Require an exact round-trip in a
        // fixed zone so validation is independent of local DST and skipped days.
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
        return components
    }

    /// Resolve a local wall time, using the first valid instant after a DST gap.
    private static func wallTime(on date: Date, hour: Int, minute: Int = 0, calendar: Calendar) -> Date {
        let matched = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)!
        if calendar.isDate(matched, inSameDayAs: date) { return matched }

        // Exact-time matching can skip a whole day for a non-hour DST gap.
        // Component construction stays on the civil day but preserves missing
        // minutes; clamp to the transition to retain the next-valid-time policy.
        var components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute
        components.second = 0
        let normalized = calendar.date(from: components)!
        if let transition = calendar.timeZone.nextDaylightSavingTimeTransition(after: calendar.startOfDay(for: date)),
           transition <= normalized, calendar.isDate(transition, inSameDayAs: date) {
            return transition
        }
        return normalized
    }

    /// Midnight at the start of this day.
    public func date(calendar: Calendar = .current) -> Date {
        calendar.plannerStorage.date(from: DayKey.parse(raw)!)!
    }
    /// The start of a planner day, using local wall time even across daylight saving changes.
    public func start(resetHour: Int, calendar: Calendar = .current) -> Date {
        let calendar = calendar.plannerStorage
        return DayKey.wallTime(on: date(calendar: calendar), hour: min(23, max(0, resetHour)), calendar: calendar)
    }

    func reminderDate(hour: Int, minute: Int, resetHour: Int, calendar: Calendar) -> Date {
        let calendar = calendar.plannerStorage
        let civilDay = hour < resetHour ? adding(days: 1, calendar: calendar) : self
        return DayKey.wallTime(on: civilDay.date(calendar: calendar), hour: hour, minute: minute, calendar: calendar)
    }

    public func adding(days n: Int, calendar: Calendar = .current) -> DayKey {
        let calendar = calendar.plannerStorage
        return DayKey(calendar.date(byAdding: .day, value: n, to: date(calendar: calendar))!, calendar: calendar)
    }
    public func weekday(calendar: Calendar = .current) -> Int {
        calendar.plannerStorage.component(.weekday, from: date(calendar: calendar))
    }
}

/// Free-form daily notes.
public struct QuickNote: Codable, Equatable, Sendable {
    public var day: DayKey
    public var text: String
    public init(day: DayKey, text: String) { self.day = day; self.text = text }
}

/// A completed or in-progress slice of focus time, used for Insights.
public struct FocusSegment: Codable, Equatable, Sendable {
    public var taskID: UUID?
    public var start: Date
    public var end: Date
    public var seconds: Double { end.timeIntervalSince(start) }
    public init(taskID: UUID?, start: Date, end: Date) { self.taskID = taskID; self.start = start; self.end = end }
}

/// How unfinished tasks from earlier days are handled when Home is opened.
public enum CarryMode: String, Codable, CaseIterable, Sendable { case ask, auto, never }

public enum NotchTimerPlacement: String, Codable, CaseIterable, Sendable { case right, left, hidden }
public enum WorkspaceTimerStyle: String, Codable, CaseIterable, Sendable { case dotMatrix, digital, minimal }
public enum NotchOpenTrigger: String, Codable, CaseIterable, Sendable { case hover, click, doubleClick }

public struct Preferences: Codable, Equatable, Sendable {
    /// Local hour at which a new planner day starts. Zero preserves midnight rollover.
    public var resetHour: Int = 0 { didSet { resetHour = min(23, max(0, resetHour)) } }
    public var carryMode: CarryMode = .ask
    public var defaultFocusMinutes: Int = 25
    public var focusCompletionSound: Bool = true
    public var notchTimerPlacement: NotchTimerPlacement = .right
    /// Digital reads at a glance; the dot-matrix face is opt-in.
    public var workspaceTimerStyle: WorkspaceTimerStyle = .digital
    public var notchOpenTrigger: NotchOpenTrigger = .hover
    public var notchOnMonitors: Bool = true
    /// nil = automatic (screen under the pointer); otherwise a display name.
    public var showOnDisplay: String? = nil
    public var remindersSync: Bool = false
    public var ringOnPhone: Bool = false
    public var sortWithAI: Bool = false
    public var includeWeekendsInStreak: Bool = true
    public var catchScreenshots: Bool = true
    public var catchCopies: Bool = false
    /// Order of Today's side-column cards (see `HomeLayout`). Older files may still list "tasks" and "insights";
    /// both are ignored there, because tasks are always shown and Insights has its own tab.
    public var workspaceCardOrder: [String] = ["focus", "events", "notepad"]
    /// The notepad is opt-in so the first screen stays clean.
    public var hiddenWorkspaceCards: [String] = ["notepad"]
    public var hiddenCalendarIDs: [String] = []
    public var welcomeCompleted: Bool = false
    public init() {}

    public init(from decoder: Decoder) throws {
        // Older files may omit new settings; present malformed settings are errors.
        let d = Preferences()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resetHour = min(23, max(0, try c.decodeMissing(Int.self, forKey: .resetHour, default: d.resetHour)))
        carryMode = try c.decodeMissing(CarryMode.self, forKey: .carryMode, default: d.carryMode)
        defaultFocusMinutes = try c.decodeMissing(Int.self, forKey: .defaultFocusMinutes, default: d.defaultFocusMinutes)
        focusCompletionSound = try c.decodeMissing(Bool.self, forKey: .focusCompletionSound, default: d.focusCompletionSound)
        notchTimerPlacement = try c.decodeMissing(NotchTimerPlacement.self, forKey: .notchTimerPlacement, default: d.notchTimerPlacement)
        workspaceTimerStyle = try c.decodeMissing(WorkspaceTimerStyle.self, forKey: .workspaceTimerStyle, default: d.workspaceTimerStyle)
        notchOpenTrigger = try c.decodeMissing(NotchOpenTrigger.self, forKey: .notchOpenTrigger, default: d.notchOpenTrigger)
        notchOnMonitors = try c.decodeMissing(Bool.self, forKey: .notchOnMonitors, default: d.notchOnMonitors)
        showOnDisplay = try c.decodeIfPresent(String.self, forKey: .showOnDisplay)
        remindersSync = try c.decodeMissing(Bool.self, forKey: .remindersSync, default: d.remindersSync)
        ringOnPhone = try c.decodeMissing(Bool.self, forKey: .ringOnPhone, default: d.ringOnPhone)
        sortWithAI = try c.decodeMissing(Bool.self, forKey: .sortWithAI, default: d.sortWithAI)
        includeWeekendsInStreak = try c.decodeMissing(Bool.self, forKey: .includeWeekendsInStreak, default: d.includeWeekendsInStreak)
        catchScreenshots = try c.decodeMissing(Bool.self, forKey: .catchScreenshots, default: d.catchScreenshots)
        catchCopies = try c.decodeMissing(Bool.self, forKey: .catchCopies, default: d.catchCopies)
        workspaceCardOrder = try c.decodeMissing([String].self, forKey: .workspaceCardOrder, default: d.workspaceCardOrder)
        hiddenWorkspaceCards = try c.decodeMissing([String].self, forKey: .hiddenWorkspaceCards, default: d.hiddenWorkspaceCards)
        hiddenCalendarIDs = try c.decodeMissing([String].self, forKey: .hiddenCalendarIDs, default: d.hiddenCalendarIDs)
        welcomeCompleted = try c.decodeMissing(Bool.self, forKey: .welcomeCompleted, default: d.welcomeCompleted)
    }
}

/// A materialized occurrence remains handled even if the user moves or deletes its task.
public struct RepeatOccurrence: Codable, Equatable, Hashable, Sendable {
    public var seriesID: UUID
    public var day: DayKey
    public init(seriesID: UUID, day: DayKey) { self.seriesID = seriesID; self.day = day }
}

/// Only absent keys get migration defaults. A present null or malformed value
/// must not silently replace persisted data with a default.
extension KeyedDecodingContainer {
    func decodeMissing<T: Decodable>(_ type: T.Type, forKey key: Key, default value: T) throws -> T {
        contains(key) ? try decode(type, forKey: key) : value
    }
}

public struct PlannerSchemaError: Error, LocalizedError, CustomStringConvertible {
    public let version: Int
    public var description: String {
        "Planner schema version \(version) is not supported (supported: 1). Open it with a compatible Perch version. No data was rewritten or restored."
    }
    public var errorDescription: String? { description }
}

/// The whole planner document, persisted as planner.json.
public struct Planner: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int = Planner.currentVersion
    public var tasks: [PlanTask] = []
    public var projects: [TaskProject] = []
    public var notes: [QuickNote] = []
    public var focusSegments: [FocusSegment] = []
    /// Keep the original on-disk key for existing planner.json documents.
    public var focusLog: [FocusSegment] {
        get { focusSegments }
        set { focusSegments = newValue }
    }
    public var focus: FocusSession? = nil
    public var dismissedOverdue: [UUID] = []
    public var repeatOccurrences: [RepeatOccurrence] = []
    /// Local completion only; IDs identify individual calendar occurrences, not series.
    public var completedCalendarEventIDs: Set<String> = []
    /// Planner day when each occurrence was checked off, for historical insights.
    public var completedCalendarEventDays: [String: DayKey] = [:]
    public var preferences: Preferences = Preferences()
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeMissing(Int.self, forKey: .version, default: Self.currentVersion)
        guard version == Self.currentVersion else { throw PlannerSchemaError(version: version) }
        tasks = try c.decodeMissing([PlanTask].self, forKey: .tasks, default: [])
        projects = try c.decodeMissing([TaskProject].self, forKey: .projects, default: [])
        notes = try c.decodeMissing([QuickNote].self, forKey: .notes, default: [])
        focusSegments = try c.decodeMissing([FocusSegment].self, forKey: .focusSegments, default: [])
        focus = try c.decodeIfPresent(FocusSession.self, forKey: .focus)
        repeatOccurrences = try c.decodeMissing([RepeatOccurrence].self, forKey: .repeatOccurrences, default: [])
        dismissedOverdue = try c.decodeMissing([UUID].self, forKey: .dismissedOverdue, default: [])
        completedCalendarEventIDs = try c.decodeMissing(Set<String>.self, forKey: .completedCalendarEventIDs, default: [])
        completedCalendarEventDays = try c.decodeMissing([String: DayKey].self, forKey: .completedCalendarEventDays, default: [:])
        preferences = try c.decodeMissing(Preferences.self, forKey: .preferences, default: Preferences())
    }
}
