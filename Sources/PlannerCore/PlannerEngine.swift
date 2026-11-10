import Foundation

public struct PlannerError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// A day reference as agents and scripts pass it: yyyy-MM-dd, today, tomorrow, yesterday or inbox.
public enum DayRef: Equatable, Sendable {
    case day(DayKey)
    case inbox

    public static func parse(
        _ s: String?, now: Date, resetHour: Int = 0, calendar: Calendar = .current, allowInbox: Bool = true
    ) throws -> DayRef {
        let today = DayKey(now, resetHour: resetHour, calendar: calendar)
        guard let raw = s?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return .day(today) }
        switch raw {
        case "today": return .day(today)
        case "tomorrow": return .day(today.adding(days: 1, calendar: calendar))
        case "yesterday": return .day(today.adding(days: -1, calendar: calendar))
        case "inbox" where allowInbox: return .inbox
        default:
            guard let d = DayKey(raw) else {
                throw PlannerError("Enter a yyyy-MM-dd date or use today, tomorrow, yesterday.")
            }
            return .day(d)
        }
    }

    public var key: DayKey? { if case .day(let d) = self { return d }; return nil }
}

/// Fields an agent (or the details editor) may change on a task. nil = leave alone.
public struct TaskEdit: Sendable {
    public var title: String?
    /// "none" clears.
    public var remindAt: String?
    public var deadline: String?
    public var priority: String?
    public var project: String?
    public var notes: String?
    public var repeatRule: String?
    public var minutes: Int?
    public var steps: [String]?
    public var doneSteps: [String]?
    public init() {}
    public var isEmpty: Bool {
        title == nil && remindAt == nil && deadline == nil && priority == nil && project == nil && notes == nil
            && repeatRule == nil && minutes == nil && steps == nil && doneSteps == nil
    }
}

public struct Insights: Equatable, Sendable {
    public struct Day: Equatable, Sendable {
        public var day: DayKey
        public var planned: Int
        public var completed: Int
        public var focusSeconds: Double
        /// Kept separate from task counts: the planner does not store all scheduled events.
        public var completedCalendarEvents: Int = 0
    }
    public var today: Day
    public var streak: Int
    public var lastSeven: [Day]
    public var previousSeven: [Day]
    /// Hours of the day (0-23) with the most focus, best first.
    public var peakHours: [Int]
    public var allTimeCompleted: Int
    public var allTimeFocusSeconds: Double
    public var allTimeCompletedCalendarEvents: Int = 0
}

/// All planner rules, as pure mutations of a `Planner` value. UI, MCP server and CLI share this.
public struct PlannerEngine {
    public var planner: Planner
    public var now: () -> Date
    public var calendar: Calendar

    public init(planner: Planner, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.planner = planner; self.now = now; self.calendar = calendar.plannerStorage
    }

    public func dayKey(_ date: Date) -> DayKey {
        DayKey(date, resetHour: planner.preferences.resetHour, calendar: calendar)
    }
    public var today: DayKey { dayKey(now()) }

    // MARK: Lookups

    public func tasks(on ref: DayRef) -> [PlanTask] {
        planner.tasks.filter { ref == .inbox ? $0.day == nil : $0.day == ref.key }
    }

    public func project(id: UUID?) -> TaskProject? { id.flatMap { i in planner.projects.first { $0.id == i } } }

    /// Resolves the same full ID, short ID or title reference accepted by task mutations.
    public func task(_ reference: String, on day: DayRef) throws -> PlanTask {
        planner.tasks[try index(of: reference, on: resolved(day))]
    }

    func index(of ref: String, on day: DayRef) throws -> Int {
        let trimmed = ref.trimmingCharacters(in: .whitespaces)
        if let id = UUID(uuidString: trimmed), let i = planner.tasks.firstIndex(where: { $0.id == id }) { return i }
        // Short ids (first 8 hex chars) are what list_tasks shows.
        let lower = trimmed.lowercased()
        if lower.count >= 6, let i = planner.tasks.firstIndex(where: { $0.id.uuidString.lowercased().hasPrefix(lower) })
        {
            return i
        }
        let pool = planner.tasks.indices.filter {
            day == .inbox ? planner.tasks[$0].day == nil : planner.tasks[$0].day == day.key
        }
        let exact = pool.filter { planner.tasks[$0].title.caseInsensitiveCompare(trimmed) == .orderedSame }
        if exact.count == 1 { return exact[0] }
        let fuzzy =
            exact.isEmpty ? pool.filter { planner.tasks[$0].title.localizedCaseInsensitiveContains(trimmed) } : exact
        if fuzzy.count == 1 { return fuzzy[0] }
        if fuzzy.count > 1 {
            let names = fuzzy.prefix(5).map { "\"\(planner.tasks[$0].title)\"" }.joined(separator: ", ")
            throw PlannerError("Multiple tasks match \"\(trimmed)\": \(names). Choose an id from list_tasks.")
        }
        let where_ = day == .inbox ? "in the Inbox" : "on \(day.key!)"
        throw PlannerError("No task found for \"\(trimmed)\" \(where_). Check list_tasks for an id.")
    }

    func requireEditable(_ t: PlanTask) throws {
        if let d = t.day, d < today { throw PlannerError("Earlier days can't be edited.") }
    }

    // MARK: Adding

    /// Adds tasks to the end of a day's list (or the Inbox). Each title is parsed like typing it.
    @discardableResult
    public mutating func addTasks(
        _ titles: [String], on day: DayRef? = nil, literal: Bool = false, agentID: String? = nil
    ) throws -> [PlanTask] {
        let lines = titles.flatMap {
            literal ? [$0.trimmingCharacters(in: .whitespacesAndNewlines)] : TaskCapture.splitLines($0)
        }
        .filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw PlannerError("Add at least one task title with text.") }
        if let d = day?.key, d < today { throw PlannerError("Can't add tasks on \(d). Choose today or a later date.") }
        let capture = TaskCapture(now: now(), resetHour: planner.preferences.resetHour, calendar: calendar)
        var added: [PlanTask] = []
        for line in lines {
            var task = PlanTask(title: line, day: day?.key ?? today, createdAt: now(), agentID: agentID)
            if !literal {
                let c = capture.parse(line)
                guard !c.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PlannerError("Add at least one task title with text.")
                }
                task.title = c.title
                if c.inbox {
                    task.day = nil
                } else if let d = c.day {
                    task.day = d
                } else if day == .inbox {
                    task.day = nil
                }
                if let d = task.day, d < today { throw PlannerError("Choose today or a later date for new tasks.") }
                task.remindAt = task.day == nil ? nil : c.remindAt
                task.deadline = c.deadline
                task.priority = c.priority
                task.repeatRule = task.day == nil ? nil : c.repeatRule
                // "gym every mon, wed" with no day named starts on the first matching weekday.
                if c.day == nil, !c.inbox, let rule = c.repeatRule, let d = task.day {
                    task.day = rule.firstOccurrence(onOrAfter: d, calendar: calendar)
                }
                task.minutes = c.minutes
                if let p = c.projectName { task.projectID = ensureProject(named: p).id }
            } else if day == .inbox {
                task.day = nil
            }
            task.repeatAnchor = task.repeatRule == nil ? nil : task.day
            planner.tasks.append(task)
            added.append(task)
        }
        return added
    }

    /// Finds a project case-insensitively, creating it if needed.
    @discardableResult
    public mutating func ensureProject(named raw: String) -> TaskProject {
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).replacingOccurrences(of: "-", with: " ")
        if let p = planner.projects.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return p }
        let palette = ["#8E8CF5", "#F5A35C", "#5CC8F5", "#7BD88F", "#F57FA3", "#E8D35C", "#B98CF5"]
        let pretty = name.prefix(1).uppercased() + name.dropFirst()
        let p = TaskProject(name: pretty, colorHex: palette[planner.projects.count % palette.count])
        planner.projects.append(p)
        return p
    }

    // MARK: Changing

    public mutating func complete(_ ref: String, on day: DayRef = .day(DayKey("1970-01-01"))) throws -> PlanTask {
        let i = try index(of: ref, on: resolved(day))
        guard planner.tasks[i].day == today else {
            throw PlannerError("Reschedule this task for today before completing it.")
        }
        guard !planner.tasks[i].done else { throw PlannerError("Already completed: \(planner.tasks[i].title).") }
        // Stop the timer first so its focus time lands on the task before we copy it.
        if planner.focus?.taskID == planner.tasks[i].id, planner.focus?.state != .finished { _ = stopTimer() }
        preserveRepeatAnchor(of: planner.tasks[i].id)
        var t = planner.tasks[i]
        t.done = true
        t.completedAt = now()
        t.steps = t.steps.map {
            var s = $0; s.done = true; return s
        }
        planner.tasks[i] = t
        if let nextDay = nextRepeatDay(for: t) { _ = materializeRepeat(t, on: nextDay) }
        return planner.tasks[i]
    }

    public mutating func reopen(_ ref: String) throws -> PlanTask {
        let i = try index(of: ref, on: .day(today))
        guard planner.tasks[i].day == today else { throw PlannerError("Reopening requires a task scheduled today.") }
        guard planner.tasks[i].done else { throw PlannerError("This task is still open: \(planner.tasks[i].title).") }
        planner.tasks[i].done = false
        planner.tasks[i].completedAt = nil
        return planner.tasks[i]
    }

    public mutating func rename(_ ref: String, on day: DayRef, to title: String) throws -> PlanTask {
        let clean = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { throw PlannerError("Enter replacement title text.") }
        let i = try index(of: ref, on: resolved(day))
        try requireEditable(planner.tasks[i])
        planner.tasks[i].title = clean
        return planner.tasks[i]
    }

    @discardableResult
    public mutating func delete(_ ref: String, on day: DayRef) throws -> PlanTask {
        let i = try index(of: ref, on: resolved(day))
        try requireEditable(planner.tasks[i])
        preserveRepeatAnchor(of: planner.tasks[i].id)
        let t = planner.tasks.remove(at: i)
        if planner.focus?.taskID == t.id { planner.focus = nil }
        return t
    }

    public mutating func move(_ ref: String, from: DayRef, to: DayRef) throws -> PlanTask {
        let i = try index(of: ref, on: resolved(from))
        preserveRepeatAnchor(of: planner.tasks[i].id)
        var t = planner.tasks[i]
        guard !t.done else { throw PlannerError("Reopen this task before continuing: \(t.title).") }
        try requireEditable(t)
        switch to {
        case .inbox:
            guard t.day != nil else { throw PlannerError("Already unscheduled in inbox: \(t.title).") }
            t.day = nil; t.remindAt = nil; t.repeatRule = nil
        case .day(let d):
            guard d >= today else { throw PlannerError("Choose today or a later date as the destination.") }
            guard t.day != d else { throw PlannerError("No move needed: \(t.title) is scheduled for \(d).") }
            if let r = t.remindAt {
                let c = calendar.dateComponents([.hour, .minute], from: r)
                t.remindAt = d.reminderDate(
                    hour: c.hour!, minute: c.minute!, resetHour: planner.preferences.resetHour, calendar: calendar)
            }
            t.day = d
        }
        planner.tasks[i] = t
        return t
    }

    /// Reorders a task within its day.
    public mutating func reorder(_ id: UUID, before other: UUID?) {
        guard let from = planner.tasks.firstIndex(where: { $0.id == id }) else { return }
        let t = planner.tasks.remove(at: from)
        if let o = other, let to = planner.tasks.firstIndex(where: { $0.id == o }) {
            planner.tasks.insert(t, at: to)
        } else {
            planner.tasks.append(t)
        }
    }

    public mutating func update(_ ref: String, on day: DayRef, _ e: TaskEdit) throws -> PlanTask {
        guard !e.isEmpty else {
            throw PlannerError(
                "Supply a field to update: title, notes, priority, project, remind_at, deadline, repeat, minutes, steps or done_steps."
            )
        }
        let i = try index(of: ref, on: resolved(day))
        preserveRepeatAnchor(of: planner.tasks[i].id)
        var t = planner.tasks[i]
        try requireEditable(t)
        var changesRepeat = false

        if let title = e.title {
            let clean = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { throw PlannerError("Enter some text for the title.") }
            t.title = clean
        }
        if let r = e.remindAt {
            if r.lowercased() == "none" {
                t.remindAt = nil
            } else {
                guard let d = t.day else {
                    throw PlannerError("Schedule \(t.title) on a date before adding reminders or repeats.")
                }
                guard !t.done else { throw PlannerError("Reopen \(t.title) before setting a reminder.") }
                let at = try parseReminder(r, on: d)
                guard at > now() else { throw PlannerError("Choose a reminder after now; \(r) is in the past.") }
                t.remindAt = at
                t.day = dayKey(at)
            }
        }
        if let d = e.deadline {
            if d.lowercased() == "none" {
                t.deadline = nil
            } else {
                guard let k = DayKey(d) else {
                    throw PlannerError("For deadline, enter yyyy-MM-dd or none to clear it.")
                }
                t.deadline = k
            }
        }
        if let p = e.priority {
            guard let v = TaskPriority(rawValue: p.lowercased()) else {
                throw PlannerError("Choose priority from: none, low, medium, high.")
            }
            t.priority = v
        }
        if let p = e.project {
            t.projectID = p.lowercased() == "none" || p.isEmpty ? nil : ensureProject(named: p).id
        }
        if let n = e.notes { t.notes = n }
        if let r = e.repeatRule {
            guard let parsed = TaskRepeat.parseRule(r) else {
                throw PlannerError(
                    "Repeat rule not recognized: \(r). Use daily, weekdays, weekly, monthly, every 2 weeks, every tue, thu, every! 4 days, or none."
                )
            }
            if parsed != nil && t.day == nil {
                throw PlannerError("Schedule \(t.title) on a date before adding reminders or repeats.")
            }
            if parsed != t.repeatRule {
                changesRepeat = true
                // Changing cadence starts a new series here; preplanned tasks remain in place.
                if parsed != nil {
                    t.repeatedFrom = UUID()
                    t.repeatAnchor = t.day
                }
            }
            t.repeatRule = parsed
        }
        if let m = e.minutes {
            guard m == 0 || (1...720).contains(m) else {
                throw PlannerError("Set minutes to an integer from 1 to 720, or 0 to clear the limit.")
            }
            if t.done && m > 0 { throw PlannerError("Reopen \(t.title) before setting a time limit.") }
            t.minutes = m == 0 ? nil : m
        }
        if let steps = e.steps {
            let old = Dictionary(t.steps.map { ($0.title.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
            t.steps = steps.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map {
                old[$0.lowercased()] ?? Subtask(title: $0)
            }
        }
        if let done = e.doneSteps {
            for s in done {
                guard let si = t.steps.firstIndex(where: { $0.title.caseInsensitiveCompare(s) == .orderedSame }) else {
                    throw PlannerError("Step not found in \(t.title): \(s). Inspect steps with get_task.")
                }
                t.steps[si].done = true
            }
        }
        if changesRepeat { try endRepeat(of: t.id) }
        planner.tasks[i] = t
        return t
    }

    public mutating func snooze(_ ref: String, minutes: Int = 5) throws -> PlanTask {
        guard (1...1440).contains(minutes) else {
            throw PlannerError("Set the snooze delay to an integer from 1 to 1440 minutes.")
        }
        let i = try index(of: ref, on: .day(today))
        guard planner.tasks[i].day != nil else {
            throw PlannerError("Schedule \(planner.tasks[i].title) on a date before snoozing it.")
        }
        guard !planner.tasks[i].done else { throw PlannerError("Already completed: \(planner.tasks[i].title).") }
        preserveRepeatAnchor(of: planner.tasks[i].id)
        let at = now().addingTimeInterval(Double(minutes) * 60)
        planner.tasks[i].remindAt = at
        planner.tasks[i].day = dayKey(at)
        return planner.tasks[i]
    }

    /// Accepts 17:30, 5:30 pm, 2026-10-30 17:30, "in 20 minutes", "tomorrow at 9".
    public func parseReminder(_ s: String, on day: DayKey) throws -> Date {
        let t = s.trimmingCharacters(in: .whitespaces)
        for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
            let f = DateFormatter()
            f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            if let d = f.date(from: t) { return d }
        }
        let cap = TaskCapture(now: now(), resetHour: planner.preferences.resetHour, calendar: calendar)
        if let m = TaskCapture.first(TaskCapture.relative, in: t) {
            let probe = cap.parse("x " + (t as NSString).substring(with: m.range))
            if let r = probe.remindAt { return r }
        }
        let withAt = t.range(of: "^\\d", options: .regularExpression) != nil ? "at " + t : t
        if let (time, _) = cap.matchTime(in: withAt) {
            let d = cap.matchDay(in: withAt, anchoredAt: nil)?.0 ?? day
            return d.reminderDate(
                hour: time.h, minute: time.m, resetHour: planner.preferences.resetHour, calendar: calendar)
        }
        throw PlannerError("Time not recognized: \(s). Try 18:15, 6:15 pm, 2026-12-01 18:15 or in 15 minutes.")
    }

    // MARK: Overdue / carry forward

    /// Applies the saved policy to unhandled overdue tasks. The caller persists the result.
    /// Repeated calls are safe, including after a file reload or logical-day rollover.
    @discardableResult
    public mutating func applyCarryMode() -> [PlanTask] {
        guard planner.preferences.carryMode != .ask else { return [] }
        let ids = overdue().map(\.id)
        switch planner.preferences.carryMode {
        case .ask: return []
        case .auto: return carryForward(ids, to: today)
        case .never:
            dismissOverdue(ids)
            return []
        }
    }

    /// Explicit exception to read-only history: finish selected, unhandled overdue tasks
    /// on their original day. This does not create repeats or move/copy any task.
    @discardableResult
    public mutating func completeOverdue(_ ids: [UUID]) -> [PlanTask] {
        let selected = Set(ids)
        let eligible = Set(overdue().map(\.id)).intersection(selected)
        guard !eligible.isEmpty else { return [] }
        let completedAt = now()
        for id in eligible { preserveRepeatAnchor(of: id) }
        if let id = planner.focus?.taskID, eligible.contains(id), planner.focus?.state != .finished {
            _ = stopTimer()
        }
        var completed: [PlanTask] = []
        for i in planner.tasks.indices where eligible.contains(planner.tasks[i].id) {
            planner.tasks[i].done = true
            planner.tasks[i].completedAt = completedAt
            planner.tasks[i].steps = planner.tasks[i].steps.map {
                var s = $0; s.done = true; return s
            }
            completed.append(planner.tasks[i])
        }
        return completed
    }

    /// Unfinished tasks from earlier days that haven't been carried forward or dismissed.
    public func overdue() -> [PlanTask] {
        let handled = Set(planner.dismissedOverdue)
        let carriedSources = Set(planner.tasks.compactMap { t in t.carriedFrom.map { "\($0)|\(t.title)" } })
        return planner.tasks.filter { t in
            guard let d = t.day, d < today, !t.done, !handled.contains(t.id) else { return false }
            return !carriedSources.contains("\(d)|\(t.title)")
        }
    }

    /// "Dismiss without creating new copies".
    public mutating func dismissOverdue(_ ids: [UUID]) {
        planner.dismissedOverdue.append(contentsOf: ids.filter { !planner.dismissedOverdue.contains($0) })
    }

    /// Copies overdue tasks to a day; their own days keep their record.
    @discardableResult
    public mutating func carryForward(_ ids: [UUID], to day: DayKey) -> [PlanTask] {
        var out: [PlanTask] = []
        for id in ids {
            preserveRepeatAnchor(of: id)
            guard let t = planner.tasks.first(where: { $0.id == id }), let from = t.day,
                from < day, !t.done, !planner.dismissedOverdue.contains(id)
            else { continue }
            if t.repeatRule != nil
                && planner.tasks.contains(where: { $0.repeatSeriesID == t.repeatSeriesID && $0.day == day })
            {
                dismissOverdue([id])
                continue
            }
            var copy = t
            copy.id = UUID(); copy.day = day; copy.carriedFrom = from; copy.createdAt = now()
            copy.carryCount += 1
            if t.repeatRule != nil {
                copy.repeatedFrom = t.repeatSeriesID
                let occurrence = RepeatOccurrence(seriesID: t.repeatSeriesID, day: day)
                if !planner.repeatOccurrences.contains(occurrence) { planner.repeatOccurrences.append(occurrence) }
            }
            copy.remindAt = nil; copy.focusedSeconds = 0; copy.reminderLink = nil
            planner.tasks.append(copy)
            dismissOverdue([id])
            out.append(copy)
        }
        return out
    }

    // MARK: Focus timer

    @discardableResult
    public mutating func startTimer(task ref: String?, minutes: Int?) throws -> FocusSession {
        if let m = minutes, !(1...720).contains(m) {
            throw PlannerError("Set the timer to an integer from 1 to 720 minutes.")
        }
        var taskID: UUID?
        var limit: Int? = minutes
        if let ref, !ref.isEmpty {
            let i = try index(of: ref, on: .day(today))
            guard planner.tasks[i].day == today else {
                throw PlannerError("Schedule this task for today before starting focus.")
            }
            guard !planner.tasks[i].done else {
                throw PlannerError("Reopen this task before starting focus: \(planner.tasks[i].title).")
            }
            taskID = planner.tasks[i].id
            if let m = minutes { planner.tasks[i].minutes = m }
            limit = minutes ?? planner.tasks[i].minutes ?? planner.preferences.defaultFocusMinutes
        } else if limit == nil {
            limit = planner.preferences.defaultFocusMinutes
        }
        if planner.focus?.state == .running || planner.focus?.state == .paused { _ = stopTimer() }
        let s = FocusSession(taskID: taskID, limit: limit.map { Double($0) * 60 }, now: now())
        planner.focus = s
        return s
    }

    /// Stopwatch on a task, no limit.
    @discardableResult
    public mutating func startStopwatch(taskID: UUID?) -> FocusSession {
        if planner.focus?.state == .running || planner.focus?.state == .paused { _ = stopTimer() }
        planner.focus = FocusSession(taskID: taskID, limit: nil, now: now())
        return planner.focus!
    }

    public mutating func pauseTimer() throws {
        guard var f = planner.focus, f.state != .finished else { throw PlannerError("Start a focus session first.") }
        guard f.state == .running else { throw PlannerError("The focus session is not running.") }
        record(f.pause(at: now()))
        planner.focus = f
    }

    public mutating func resumeTimer() throws {
        guard var f = planner.focus, f.state != .finished else { throw PlannerError("Start a focus session first.") }
        guard f.state == .paused else { throw PlannerError("The focus session is not on hold.") }
        f.resume(at: now())
        planner.focus = f
    }

    /// Stops without completing the task.
    @discardableResult
    public mutating func stopTimer() -> FocusSegment? {
        guard var f = planner.focus, f.state != .finished else { return nil }
        let seg = f.finish(at: now())
        // Ignore an accidental subsecond stop, but preserve fractional tails
        // after time was already banked (including an explicit checkpoint).
        if let seg, seg.seconds >= 1 || f.banked > seg.seconds {
            record(seg)
        }
        planner.focus = nil
        return seg
    }

    public static let focusCheckpointInterval: TimeInterval = 30

    /// The caller persists this mutation on its regular tick. True means a countdown just finished.
    public mutating func tick() -> Bool {
        let time = now()
        guard var f = planner.focus, f.state == .running else { return false }
        if f.isOver(at: time) {
            record(f.finish(at: time))
            planner.focus = f
            return true
        }
        if let start = f.resumedAt, time.timeIntervalSince(start) >= Self.focusCheckpointInterval {
            record(f.checkpoint(at: time))
            planner.focus = f
        }
        return false
    }

    /// Call under PlannerFile.mutate to durably bank time without changing timer state.
    @discardableResult
    public mutating func checkpointFocus() -> Bool {
        guard var f = planner.focus, let segment = f.checkpoint(at: now()) else { return false }
        record(segment)
        planner.focus = f
        return true
    }

    /// Call once at app startup, not on every file refresh. Offline time is not focus time.
    @discardableResult
    public mutating func recoverFocus() -> Bool {
        guard var f = planner.focus, f.state == .running else { return false }
        f.state = .paused; f.resumedAt = nil
        planner.focus = f
        return true
    }

    public mutating func extendTimer(minutes: Int = 5) {
        guard var f = planner.focus else { return }
        if f.state == .finished { f.state = .paused }
        f.extend(by: Double(minutes) * 60)
        planner.focus = f
    }

    mutating func record(_ seg: FocusSegment?) {
        guard let seg, seg.seconds > 0 else { return }
        planner.focusSegments.append(seg)
        if let id = seg.taskID, let i = planner.tasks.firstIndex(where: { $0.id == id }) {
            planner.tasks[i].focusedSeconds += seg.seconds
        }
    }

    // MARK: Notepad

    public func notepad(on day: DayKey) -> String {
        planner.notes.first { $0.day == day }?.text ?? ""
    }

    public mutating func writeNotepad(on day: DayKey, text: String, mode: String = "append") throws {
        guard day >= today else { throw PlannerError("Earlier days can't be edited.") }
        guard mode == "append" || mode == "replace" else { throw PlannerError("Choose note mode: append or replace.") }
        guard text.count <= 20_000 else { throw PlannerError("Enter note text using 20000 characters or fewer.") }
        let current = notepad(on: day)
        let next = mode == "replace" ? text : (current.isEmpty ? text : current + "\n" + text)
        if let i = planner.notes.firstIndex(where: { $0.day == day }) {
            planner.notes[i].text = next
        } else {
            planner.notes.append(QuickNote(day: day, text: next))
        }
    }

    public mutating func setNotepad(on day: DayKey, text: String) {
        if let i = planner.notes.firstIndex(where: { $0.day == day }) {
            planner.notes[i].text = text
        } else {
            planner.notes.append(QuickNote(day: day, text: text))
        }
    }

    /// ⌘↩ on a notepad line: turn it into a task on that day.
    @discardableResult
    public mutating func lineToTask(_ line: String, day: DayKey) throws -> PlanTask? {
        try addTasks([line], on: .day(day)).first
    }

    // MARK: Insights

    public func insights() -> Insights {
        let calendarCompletions = planner.completedCalendarEventIDs.reduce(into: [DayKey: Int]()) { counts, id in
            if let day = planner.completedCalendarEventDays[id] { counts[day, default: 0] += 1 }
        }
        func summary(_ d: DayKey) -> Insights.Day {
            let ts = planner.tasks.filter { $0.day == d }
            let start = d.start(resetHour: planner.preferences.resetHour, calendar: calendar)
            let end = d.adding(days: 1, calendar: calendar).start(
                resetHour: planner.preferences.resetHour, calendar: calendar)
            let focus = focusActivity.reduce(0) {
                $0 + max(0, min($1.end, end).timeIntervalSince(max($1.start, start)))
            }
            return .init(
                day: d, planned: ts.count, completed: ts.filter(\.done).count,
                focusSeconds: focus, completedCalendarEvents: calendarCompletions[d, default: 0])
        }
        let last = (0..<7).reversed().map { summary(today.adding(days: -$0, calendar: calendar)) }
        let prev = (7..<14).reversed().map { summary(today.adding(days: -$0, calendar: calendar)) }

        // Streak: consecutive days (ending today, or yesterday if today is still empty) with a completion.
        var streak = 0
        var d = today
        if summary(d).completed == 0 { d = d.adding(days: -1, calendar: calendar) }
        while true {
            let weekend = [1, 7].contains(d.weekday(calendar: calendar))
            let s = summary(d)
            if s.completed > 0 {
                streak += 1
            } else if !(weekend && !planner.preferences.includeWeekendsInStreak) {
                break
            }
            d = d.adding(days: -1, calendar: calendar)
            if streak > 3650 { break }
        }

        let byHour = activityByHour(since: .distantPast)
        let peaks = byHour.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(3).map(\.key)

        return Insights(
            today: summary(today), streak: streak, lastSeven: last, previousSeven: prev, peakHours: peaks,
            allTimeCompleted: planner.tasks.filter(\.done).count,
            allTimeFocusSeconds: focusActivity.reduce(0) { $0 + $1.seconds },
            allTimeCompletedCalendarEvents: planner.completedCalendarEventIDs.count)
    }

    // MARK: Helpers

    /// Sentinel default day = "any day" so ids work regardless of which day is passed.
    func resolved(_ d: DayRef) -> DayRef {
        if case .day(let k) = d, k.raw == "1970-01-01" { return .day(today) }
        return d
    }
}
