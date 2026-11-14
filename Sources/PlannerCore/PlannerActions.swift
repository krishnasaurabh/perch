import Foundation

/// Explicit edit intent. Optional values can be cleared without confusing omission with nil.
public enum FieldChange<Value> {
    case keep
    case set(Value)
    func apply(to value: inout Value) { if case .set(let next) = self { value = next } }
}

public struct TaskChanges {
    public var title: FieldChange<String> = .keep
    public var notes: FieldChange<String> = .keep
    public var priority: FieldChange<TaskPriority> = .keep
    public var projectID: FieldChange<UUID?> = .keep
    public var startAt: FieldChange<Date?> = .keep
    public var remindAt: FieldChange<Date?> = .keep
    public var deadline: FieldChange<DayKey?> = .keep
    public var minutes: FieldChange<Int?> = .keep
    public var steps: FieldChange<[Subtask]> = .keep
    public init() {}

    /// Build an edit from a UI draft without accepting changes to identity, history or runtime fields.
    public init(before: PlanTask, draft: PlanTask) throws {
        self.init()
        var permitted = before
        permitted.title = draft.title; permitted.notes = draft.notes; permitted.priority = draft.priority
        permitted.projectID = draft.projectID; permitted.remindAt = draft.remindAt
        permitted.startAt = draft.startAt
        permitted.deadline = draft.deadline; permitted.minutes = draft.minutes; permitted.steps = draft.steps
        guard permitted == draft else { throw PlannerError("Use a task action to change its schedule or completion.") }
        if before.title != draft.title { title = .set(draft.title) }
        if before.notes != draft.notes { notes = .set(draft.notes) }
        if before.priority != draft.priority { priority = .set(draft.priority) }
        if before.projectID != draft.projectID { projectID = .set(draft.projectID) }
        if before.startAt != draft.startAt { startAt = .set(draft.startAt) }
        if before.remindAt != draft.remindAt { remindAt = .set(draft.remindAt) }
        if before.deadline != draft.deadline { deadline = .set(draft.deadline) }
        if before.minutes != draft.minutes { minutes = .set(draft.minutes) }
        if before.steps != draft.steps { steps = .set(draft.steps) }
    }
}

/// All durable planner commands. Task identity never accepts title text or partial IDs.
public enum PlannerAction {
    case addTasks([String], day: DayRef?, literal: Bool, agentID: String?)
    case complete(UUID), reopen(UUID), rename(UUID, String), delete(UUID)
    case move(UUID, DayRef), reorder(UUID, before: UUID?)
    case setStart(UUID, Date?)
    case parkThought(String), removeThought(UUID), reorderThought(UUID, before: UUID?), emptyParkingLot
    case promoteThought(UUID, day: DayKey?, agentID: String?)
    case bringOver
    case update(UUID, TaskEdit), editTask(UUID, TaskChanges)
    case snooze(UUID, minutes: Int), endRepeat(UUID)
    case completeOverdue([UUID]), carryForward([UUID], DayKey), dismissOverdue([UUID])
    case startTimer(UUID?, minutes: Int?), startStopwatch(UUID?)
    case pauseTimer, resumeTimer, stopTimer, extendTimer(Int), tick, checkpointFocus, recoverFocus
    case writeNotepad(DayKey, String, mode: String)
    case calendarCompletion(String, Bool)
    case preferences(Preferences)
    case reminderLinks([UUID: String])
    case deleteProject(UUID)
    case suggest(UUID, priority: TaskPriority, projectID: UUID?)
    case lifecycle(PlannerLifecycle)
    #if DEBUG || PERCH_TESTING
        /// Explicit synthetic preview initialization; rejected unless the document is empty.
        case seedPreview(PlannerPreview)
    #endif
}

#if DEBUG || PERCH_TESTING
    public enum PlannerPreview { case empty, three, timer, insights }
#endif

public enum PlannerLifecycle {
    case launch
    case openDay(DayKey)
    case dayChanged
}

public struct PlannerActionResult: Sendable {
    public var tasks: [PlanTask] = []
    public var thoughts: [ParkedThought] = []
    public var focus: FocusSession?
    public var flag = false
    public init() {}
}

extension PlannerEngine {
    /// Failed actions never leave even an in-memory partially mutated planner.
    @discardableResult
    public mutating func execute(_ action: PlannerAction) throws -> PlannerActionResult {
        var candidate = self
        var result = try candidate.reduce(action)
        // Generated occurrences share their template's wall time, not its absolute date.
        if candidate.planner.tasks.count > planner.tasks.count {
            let knownIDs = Set(planner.tasks.map(\.id))
            let series = Dictionary(grouping: planner.tasks.filter { $0.repeatRule != nil }, by: \.repeatSeriesID)
            for index in candidate.planner.tasks.indices {
                let task = candidate.planner.tasks[index]
                guard !knownIDs.contains(task.id), task.repeatedFrom != nil, task.startAt == nil,
                    let day = task.day,
                    let source = series[task.repeatSeriesID]?.filter({ ($0.day ?? day) <= day }).max(by: {
                        ($0.day ?? day) < ($1.day ?? day)
                    })
                else { continue }
                candidate.planner.tasks[index].startAt = candidate.startTime(source.startAt, on: day)
            }
        }
        candidate.planner.stampTaskChanges(from: planner, at: now())
        let current = Dictionary(candidate.planner.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        result.tasks = result.tasks.map { current[$0.id] ?? $0 }
        self = candidate
        return result
    }

    private mutating func reduce(_ action: PlannerAction) throws -> PlannerActionResult {
        var result = PlannerActionResult()
        switch action {
        case let .addTasks(titles, day, literal, agentID):
            result.tasks = try addTasks(titles, on: day, literal: literal, agentID: agentID)
        case .complete(let id): result.tasks = [try complete(id)]
        case .reopen(let id): result.tasks = [try reopen(id)]
        case let .rename(id, title): result.tasks = [try rename(id, on: .day(today), to: title)]
        case .delete(let id): result.tasks = [try delete(id, on: .day(today))]
        case let .move(id, day): result.tasks = [try move(id, from: .day(today), to: day)]
        case let .reorder(id, before): try reorder(id, before: before)
        case let .setStart(id, time):
            var changes = TaskChanges()
            changes.startAt = .set(time)
            result.tasks = [try editTask(id, changes)]
        case .parkThought(let text): result.thoughts = [try parkThought(text)]
        case .removeThought(let id): result.thoughts = [try removeThought(id)]
        case let .reorderThought(id, before): try reorderThought(id, before: before)
        case .emptyParkingLot:
            result.thoughts = planner.parkedThoughts
            planner.parkedThoughts.removeAll()
        case let .promoteThought(id, day, agentID): result.tasks = [try promoteThought(id, on: day, agentID: agentID)]
        case .bringOver: result.tasks = bringOver()
        case let .update(id, edit): result.tasks = [try update(id, on: .day(today), edit)]
        case let .editTask(id, changes): result.tasks = [try editTask(id, changes)]
        case let .snooze(id, minutes):
            try requireEditable(task(id))
            result.tasks = [try snooze(id, minutes: minutes)]
        case .endRepeat(let id): try endRepeat(of: id)
        case .completeOverdue(let ids): result.tasks = completeOverdue(ids)
        case let .carryForward(ids, day):
            guard day >= today else { throw PlannerError("Choose today or a later date as the destination.") }
            result.tasks = carryForward(ids, to: day)
        case .dismissOverdue(let ids):
            let eligible = Set(overdue().map(\.id))
            dismissOverdue(ids.filter { eligible.contains($0) })
        case let .startTimer(id, minutes): result.focus = try startTimer(task: id, minutes: minutes)
        case .startStopwatch(let id): result.focus = try startStopwatch(taskID: id)
        case .pauseTimer: try pauseTimer()
        case .resumeTimer: try resumeTimer()
        case .stopTimer: _ = stopTimer()
        case .extendTimer(let minutes): try extendTimer(minutes: minutes)
        case .tick: result.flag = tick()
        case .checkpointFocus: result.flag = checkpointFocus()
        case .recoverFocus: result.flag = recoverFocus()
        case let .writeNotepad(day, text, mode): try writeNotepad(on: day, text: text, mode: mode)
        case let .calendarCompletion(id, completed): try setCalendarEventCompleted(id, completed: completed)
        case .preferences(let value):
            guard (0...23).contains(value.resetHour), (1...720).contains(value.defaultFocusMinutes) else {
                throw PlannerError("Choose a reset hour from 0 to 23 and a focus duration from 1 to 720 minutes.")
            }
            let previousDay = today
            let changedPolicy = value.carryMode != planner.preferences.carryMode
            planner.preferences = value
            if changedPolicy || previousDay != today {
                _ = applyRepeats(on: today)
                _ = applyCarryMode()
            }
        case .deleteProject(let id): try deleteProject(id)
        case .reminderLinks(let links):
            for (id, link) in links {
                if let i = planner.tasks.firstIndex(where: { $0.id == id }) { planner.tasks[i].reminderLink = link }
            }
        case let .suggest(id, priority, projectID):
            let old = try task(id)
            // A slow background suggestion must not undo a later user choice or edit history.
            guard old.day == nil || old.day! >= today, !old.done else { return result }
            var changes = TaskChanges()
            if old.priority == .none { changes.priority = .set(priority) }
            if old.projectID == nil, let projectID { changes.projectID = .set(projectID) }
            result.tasks = [try editTask(id, changes)]
        case .lifecycle(let event):
            switch event {
            case .launch:
                _ = recoverFocus()
                _ = applyRepeats(on: today)
                _ = applyCarryMode()
            case .dayChanged:
                _ = applyRepeats(on: today)
                _ = applyCarryMode()
            case .openDay(let day):
                // Browsing history must not create tasks on an earlier day.
                if day >= today { result.tasks = applyRepeats(on: day) }
            }
        #if DEBUG || PERCH_TESTING
            case .seedPreview(let scenario):
                guard planner.tasks.isEmpty, planner.notes.isEmpty, planner.focus == nil,
                    planner.focusSegments.isEmpty, planner.projects.isEmpty
                else {
                    throw PlannerError("Preview initialization needs an empty planner.")
                }
                planner.preferences.welcomeCompleted = true
                switch scenario {
                case .empty: break
                case .three, .timer:
                    let added = try addTasks(
                        ["Draft the test checklist !high #work", "Review the release notes", "Choose a desk plant"],
                        on: .day(today))
                    if case .timer = scenario { _ = try startTimer(task: added[0].id, minutes: 45) }
                case .insights:
                    let doneByDay = [2, 4, 3, 5, 1, 6, 4, 3, 2, 3, 2, 0, 3, 2]
                    for (i, done) in doneByDay.enumerated() {
                        let ago = doneByDay.count - 1 - i
                        let date = calendar.date(byAdding: .day, value: -ago, to: now())!
                        let day = dayKey(date)
                        for n in 0..<(done + 1 + i % 2) {
                            let at = calendar.date(bySettingHour: 9 + n, minute: 15, second: 0, of: date) ?? date
                            planner.tasks.append(
                                PlanTask(
                                    title: "Task \(n + 1)", day: day, done: n < done, completedAt: n < done ? at : nil,
                                    createdAt: date))
                        }
                        if ago > 0, done > 0,
                            let start = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: date)
                        {
                            planner.focusSegments.append(
                                FocusSegment(
                                    taskID: nil, start: start, end: start.addingTimeInterval(Double(done) * 600)))
                        }
                    }
                }
        #endif
        }
        return result
    }

    private mutating func editTask(_ id: UUID, _ changes: TaskChanges) throws -> PlanTask {
        let i = try index(of: id)
        let old = planner.tasks[i]
        try requireEditable(old)
        var next = old
        changes.title.apply(to: &next.title); changes.notes.apply(to: &next.notes)
        changes.priority.apply(to: &next.priority); changes.projectID.apply(to: &next.projectID)
        changes.startAt.apply(to: &next.startAt)
        changes.remindAt.apply(to: &next.remindAt); changes.deadline.apply(to: &next.deadline)
        changes.minutes.apply(to: &next.minutes); changes.steps.apply(to: &next.steps)
        next.title = next.title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !next.title.isEmpty else { throw PlannerError("Enter some text for the title.") }
        if let minutes = next.minutes {
            guard (1...720).contains(minutes) else { throw PlannerError("Set minutes to an integer from 1 to 720.") }
            if old.minutes != next.minutes && old.done {
                throw PlannerError("Reopen this task before setting a time limit.")
            }
        }
        if let projectID = next.projectID {
            guard planner.projects.contains(where: { $0.id == projectID }) else {
                throw PlannerError("Project id not found.")
            }
        }
        if next.remindAt != old.remindAt, let at = next.remindAt {
            guard old.day != nil, !old.done, at.timeIntervalSince1970.isFinite, at > now() else {
                throw PlannerError("Choose a future reminder for an open, scheduled task.")
            }
            preserveRepeatAnchor(of: id)
            next.repeatAnchor = planner.tasks[i].repeatAnchor
            next.day = dayKey(at)
        }
        if next.day != old.day, case .keep = changes.startAt, let day = next.day {
            next.startAt = startTime(old.startAt, on: day)
        }
        if next.startAt != old.startAt { try validateStart(next.startAt, for: next) }
        guard Set(next.steps.map(\.id)).count == next.steps.count,
            next.steps.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else {
            throw PlannerError("Steps need distinct ids and non-empty titles.")
        }
        planner.tasks[i] = next
        return next
    }
}
