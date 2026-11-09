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
    /// yyyy-MM-dd in the user's calendar, nil = Inbox.
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
    /// Stable root task ID shared by every generated repeat in a series.
    public var repeatedFrom: UUID?
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
        repeatedFrom: UUID? = nil, carryCount: Int = 0, agentID: String? = nil
    ) {
        self.id = id; self.title = title; self.day = day; self.done = done
        self.completedAt = completedAt; self.createdAt = createdAt; self.remindAt = remindAt
        self.deadline = deadline; self.priority = priority; self.projectID = projectID
        self.notes = notes; self.repeatRule = repeatRule; self.minutes = minutes; self.steps = steps
        self.focusedSeconds = focusedSeconds; self.carriedFrom = carriedFrom; self.reminderLink = reminderLink
        self.repeatedFrom = repeatedFrom; self.carryCount = carryCount; self.agentID = agentID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        day = try c.decodeIfPresent(DayKey.self, forKey: .day)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        remindAt = try c.decodeIfPresent(Date.self, forKey: .remindAt)
        deadline = try c.decodeIfPresent(DayKey.self, forKey: .deadline)
        priority = try c.decodeIfPresent(TaskPriority.self, forKey: .priority) ?? .none
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        repeatRule = try c.decodeIfPresent(TaskRepeat.self, forKey: .repeatRule)
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes)
        steps = try c.decodeIfPresent([Subtask].self, forKey: .steps) ?? []
        focusedSeconds = try c.decodeIfPresent(Double.self, forKey: .focusedSeconds) ?? 0
        carriedFrom = try c.decodeIfPresent(DayKey.self, forKey: .carriedFrom)
        reminderLink = try c.decodeIfPresent(String.self, forKey: .reminderLink)
        repeatedFrom = try c.decodeIfPresent(UUID.self, forKey: .repeatedFrom)
        carryCount = try c.decodeIfPresent(Int.self, forKey: .carryCount) ?? 0
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
    public init(stringLiteral value: String) { self.raw = value }
    public init(_ date: Date, resetHour: Int = 0, calendar: Calendar = .current) {
        let boundary = calendar.date(bySettingHour: min(23, max(0, resetHour)), minute: 0, second: 0, of: date)!
        let logicalDate = date < boundary ? calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: date))! : date
        let c = calendar.dateComponents([.year, .month, .day], from: logicalDate)
        raw = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    public init(from decoder: Decoder) throws { raw = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(raw)
    }
    public var description: String { raw }
    public static func < (a: DayKey, b: DayKey) -> Bool { a.raw < b.raw }

    static func parse(_ s: String) -> DateComponents? {
        let p = s.split(separator: "-")
        guard p.count == 3, p[0].count == 4, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
              (1...12).contains(m), (1...31).contains(d),
              s == String(format: "%04d-%02d-%02d", y, m, d) else { return nil }
        let components = DateComponents(year: y, month: m, day: d)
        // Calendar normalizes impossible dates. Require an exact round-trip in a
        // fixed zone so validation is independent of local DST and skipped days.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
        return components
    }

    /// Midnight at the start of this day.
    public func date(calendar: Calendar = .current) -> Date {
        calendar.date(from: DayKey.parse(raw)!)!
    }
    /// The start of a planner day, using local wall time even across daylight saving changes.
    public func start(resetHour: Int, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: min(23, max(0, resetHour)), minute: 0, second: 0, of: date(calendar: calendar))!
    }

    func reminderDate(hour: Int, minute: Int, resetHour: Int, calendar: Calendar) -> Date {
        let civilDay = hour < resetHour ? adding(days: 1, calendar: calendar) : self
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: civilDay.date(calendar: calendar))!
    }

    public func adding(days n: Int, calendar: Calendar = .current) -> DayKey {
        DayKey(calendar.date(byAdding: .day, value: n, to: date(calendar: calendar))!, calendar: calendar)
    }
    public func weekday(calendar: Calendar = .current) -> Int {
        calendar.component(.weekday, from: date(calendar: calendar))
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
        // Tolerant decoding so new preferences never break an old file.
        let d = Preferences()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resetHour = min(23, max(0, (try? c.decode(Int.self, forKey: .resetHour)) ?? d.resetHour))
        carryMode = (try? c.decode(CarryMode.self, forKey: .carryMode)) ?? d.carryMode
        defaultFocusMinutes = (try? c.decode(Int.self, forKey: .defaultFocusMinutes)) ?? d.defaultFocusMinutes
        focusCompletionSound = (try? c.decode(Bool.self, forKey: .focusCompletionSound)) ?? d.focusCompletionSound
        notchTimerPlacement = (try? c.decode(NotchTimerPlacement.self, forKey: .notchTimerPlacement)) ?? d.notchTimerPlacement
        workspaceTimerStyle = (try? c.decode(WorkspaceTimerStyle.self, forKey: .workspaceTimerStyle)) ?? d.workspaceTimerStyle
        notchOpenTrigger = (try? c.decode(NotchOpenTrigger.self, forKey: .notchOpenTrigger)) ?? d.notchOpenTrigger
        notchOnMonitors = (try? c.decode(Bool.self, forKey: .notchOnMonitors)) ?? d.notchOnMonitors
        showOnDisplay = try? c.decodeIfPresent(String.self, forKey: .showOnDisplay)
        remindersSync = (try? c.decode(Bool.self, forKey: .remindersSync)) ?? d.remindersSync
        ringOnPhone = (try? c.decode(Bool.self, forKey: .ringOnPhone)) ?? d.ringOnPhone
        sortWithAI = (try? c.decode(Bool.self, forKey: .sortWithAI)) ?? d.sortWithAI
        includeWeekendsInStreak = (try? c.decode(Bool.self, forKey: .includeWeekendsInStreak)) ?? d.includeWeekendsInStreak
        catchScreenshots = (try? c.decode(Bool.self, forKey: .catchScreenshots)) ?? d.catchScreenshots
        catchCopies = (try? c.decode(Bool.self, forKey: .catchCopies)) ?? d.catchCopies
        workspaceCardOrder = (try? c.decode([String].self, forKey: .workspaceCardOrder)) ?? d.workspaceCardOrder
        hiddenWorkspaceCards = (try? c.decode([String].self, forKey: .hiddenWorkspaceCards)) ?? d.hiddenWorkspaceCards
        hiddenCalendarIDs = (try? c.decode([String].self, forKey: .hiddenCalendarIDs)) ?? d.hiddenCalendarIDs
        welcomeCompleted = (try? c.decode(Bool.self, forKey: .welcomeCompleted)) ?? d.welcomeCompleted
    }
}

/// A materialized occurrence remains handled even if the user moves or deletes its task.
public struct RepeatOccurrence: Codable, Equatable, Hashable, Sendable {
    public var seriesID: UUID
    public var day: DayKey
    public init(seriesID: UUID, day: DayKey) { self.seriesID = seriesID; self.day = day }
}

/// The whole planner document, persisted as planner.json.
public struct Planner: Codable, Equatable, Sendable {
    public var version: Int = 1
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
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        tasks = (try? c.decode([PlanTask].self, forKey: .tasks)) ?? []
        projects = (try? c.decode([TaskProject].self, forKey: .projects)) ?? []
        notes = (try? c.decode([QuickNote].self, forKey: .notes)) ?? []
        focusSegments = (try? c.decode([FocusSegment].self, forKey: .focusSegments)) ?? []
        focus = try? c.decodeIfPresent(FocusSession.self, forKey: .focus)
        repeatOccurrences = (try? c.decode([RepeatOccurrence].self, forKey: .repeatOccurrences)) ?? []
        dismissedOverdue = (try? c.decode([UUID].self, forKey: .dismissedOverdue)) ?? []
        completedCalendarEventIDs = (try? c.decode(Set<String>.self, forKey: .completedCalendarEventIDs)) ?? []
        completedCalendarEventDays = (try? c.decode([String: DayKey].self, forKey: .completedCalendarEventDays)) ?? [:]
        preferences = (try? c.decode(Preferences.self, forKey: .preferences)) ?? Preferences()
    }
}
