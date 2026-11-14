import Foundation

public protocol PlannerClock { var now: Date { get } }
public struct SystemPlannerClock: PlannerClock {
    public init() {}
    public var now: Date { Date() }
}
public struct ClosurePlannerClock: PlannerClock {
    private let value: () -> Date
    public init(_ value: @escaping () -> Date) { self.value = value }
    public var now: Date { value() }
}

/// User commands produce conditional undo steps; background work preserves both stacks.
public enum PlannerCommandOrigin { case user, background }

public struct PlannerCommandResult<Value> {
    public let value: Value
    public let before: Planner
    public let state: Planner
}

extension PlannerCommandResult: Sendable where Value: Sendable {}

/// A scoped command session. The planner is a value snapshot, never a writable reference.
public final class PlannerCommands {
    fileprivate var engine: PlannerEngine
    private let writable: Bool
    fileprivate init(engine: PlannerEngine, writable: Bool) { self.engine = engine; self.writable = writable }
    public var planner: Planner { engine.planner }
    func withAgentEngine<T>(_ body: (inout PlannerEngine) throws -> T) throws -> T {
        guard writable else { throw PlannerError("This planner session is read-only.") }; return try body(&engine)
    }
    public var today: DayKey { engine.today }
    public var read: PlannerEngine { engine }
    public func dayKey(_ date: Date) -> DayKey { engine.dayKey(date) }
    public func task(_ id: UUID) throws -> PlanTask { try engine.task(id) }

    @discardableResult
    public func execute(_ action: PlannerAction) throws -> PlannerActionResult {
        guard writable else { throw PlannerError("This planner session is read-only.") }
        return try engine.execute(action)
    }

    @discardableResult
    public func addTasks(
        _ titles: [String], on day: DayRef? = nil, literal: Bool = false, agentID: String? = nil,
        language: TaskParserLanguage = .english
    ) throws -> [PlanTask] {
        switch language {
        case .english:
            try execute(.addTasks(titles, day: day, literal: literal, agentID: agentID)).tasks
        }
    }
    @discardableResult public func complete(_ id: UUID) throws -> PlanTask { try execute(.complete(id)).tasks[0] }
    @discardableResult public func reopen(_ id: UUID) throws -> PlanTask { try execute(.reopen(id)).tasks[0] }
    @discardableResult public func rename(_ id: UUID, on day: DayRef, to title: String) throws -> PlanTask {
        try execute(.rename(id, title)).tasks[0]
    }
    @discardableResult public func delete(_ id: UUID, on day: DayRef) throws -> PlanTask {
        try execute(.delete(id)).tasks[0]
    }
    @discardableResult public func move(_ id: UUID, from: DayRef, to: DayRef) throws -> PlanTask {
        try execute(.move(id, to)).tasks[0]
    }
    public func reorder(_ id: UUID, before: UUID?) throws { try execute(.reorder(id, before: before)) }
    public func setStart(_ id: UUID, at time: Date?) throws { try execute(.setStart(id, time)) }
    @discardableResult public func parkThought(_ text: String) throws -> ParkedThought {
        try execute(.parkThought(text)).thoughts[0]
    }
    @discardableResult public func removeThought(_ id: UUID) throws -> ParkedThought {
        try execute(.removeThought(id)).thoughts[0]
    }
    public func reorderThought(_ id: UUID, before: UUID?) throws { try execute(.reorderThought(id, before: before)) }
    public func emptyParkingLot() throws { try execute(.emptyParkingLot) }
    @discardableResult
    public func promoteThought(_ id: UUID, on day: DayKey? = nil, agentID: String? = nil) throws -> PlanTask {
        try execute(.promoteThought(id, day: day, agentID: agentID)).tasks[0]
    }
    @discardableResult public func bringOver() throws -> [PlanTask] { try execute(.bringOver).tasks }
    @discardableResult public func update(_ id: UUID, on day: DayRef, _ edit: TaskEdit) throws -> PlanTask {
        try execute(.update(id, edit)).tasks[0]
    }
    @discardableResult public func snooze(_ id: UUID, minutes: Int = 5) throws -> PlanTask {
        try execute(.snooze(id, minutes: minutes)).tasks[0]
    }
    public func endRepeat(of id: UUID) throws { try execute(.endRepeat(id)) }
    @discardableResult public func completeOverdue(_ ids: [UUID]) throws -> [PlanTask] {
        try execute(.completeOverdue(ids)).tasks
    }
    @discardableResult public func carryForward(_ ids: [UUID], to day: DayKey) throws -> [PlanTask] {
        try execute(.carryForward(ids, day)).tasks
    }
    public func dismissOverdue(_ ids: [UUID]) throws { try execute(.dismissOverdue(ids)) }
    @discardableResult public func startTimer(task id: UUID?, minutes: Int?) throws -> FocusSession {
        try execute(.startTimer(id, minutes: minutes)).focus!
    }
    @discardableResult public func startStopwatch(taskID: UUID?) throws -> FocusSession {
        try execute(.startStopwatch(taskID)).focus!
    }
    public func pauseTimer() throws { try execute(.pauseTimer) }
    public func resumeTimer() throws { try execute(.resumeTimer) }
    public func stopTimer() throws { try execute(.stopTimer) }
    public func extendTimer(minutes: Int = 5) throws { try execute(.extendTimer(minutes)) }
    @discardableResult public func tick() throws -> Bool { try execute(.tick).flag }
    @discardableResult public func checkpointFocus() throws -> Bool { try execute(.checkpointFocus).flag }
    @discardableResult public func recoverFocus() throws -> Bool { try execute(.recoverFocus).flag }
    public func writeNotepad(on day: DayKey, text: String, mode: String = "append") throws {
        try execute(.writeNotepad(day, text, mode: mode))
    }
    @discardableResult public func lineToTask(_ line: String, day: DayKey) throws -> PlanTask? {
        try addTasks([line], on: .day(day)).first
    }
    public func setCalendarEventCompleted(_ id: String, completed: Bool) throws {
        try execute(.calendarCompletion(id, completed))
    }
    public func updatePrefs(_ change: (inout Preferences) -> Void) throws {
        var draft = planner.preferences
        change(&draft)
        try execute(.preferences(draft))
    }
    public func updateTask(_ id: UUID, _ change: (inout PlanTask) -> Void) throws {
        let before = try task(id)
        var draft = before
        change(&draft)
        try execute(.editTask(id, TaskChanges(before: before, draft: draft)))
    }
    public func deleteProject(_ id: UUID) throws {
        try execute(.deleteProject(id))
    }
}

/// One lock/load/validate/save path for app, CLI and MCP. A failed command leaves state and undo unchanged.
public final class PlannerCommandPipeline {
    public let file: PlannerFile
    private let clock: any PlannerClock
    private let calendar: Calendar
    private let gate = NSLock()
    private var history = PlannerUndoHistory()
    private let agentUndoOrdering = AgentUndoOrdering()

    public init(file: PlannerFile, clock: any PlannerClock = SystemPlannerClock(), calendar: Calendar = .current) {
        self.file = file; self.clock = clock; self.calendar = calendar
    }
    public var canUndo: Bool {
        gate.lock(); defer { gate.unlock() };
        return history.canUndo || agentUndoOrdering.canUndo(file: file)
    }
    public var canRedo: Bool { gate.lock(); defer { gate.unlock() }; return history.canRedo }

    public func inspect<T>(_ body: (PlannerCommands) throws -> T) throws -> T {
        let time = clock.now
        return try body(
            PlannerCommands(
                engine: PlannerEngine(planner: file.snapshot(), now: { time }, calendar: calendar), writable: false))
    }

    @discardableResult
    public func execute(_ action: PlannerAction, origin: PlannerCommandOrigin) throws -> PlannerCommandResult<
        PlannerActionResult
    > {
        try perform(origin: origin) { try $0.execute(action) }
    }

    @discardableResult
    public func perform<T>(origin: PlannerCommandOrigin, _ body: (PlannerCommands) throws -> T) throws
        -> PlannerCommandResult<T>
    {
        gate.lock(); defer { gate.unlock() }
        let time = clock.now
        let result = try file.mutate { planner in
            let before = planner
            let commands = PlannerCommands(
                engine: PlannerEngine(planner: planner, now: { time }, calendar: calendar), writable: true)
            let value = try body(commands)
            planner = commands.planner
            planner.stampTaskChanges(from: before, at: time)
            return PlannerCommandResult(value: value, before: before, state: planner)
        }
        if origin == .user {
            history.record(before: result.before, after: result.state);
            agentUndoOrdering.record(before: result.before, after: result.state)
        }
        return result
    }

    @discardableResult public func undo() throws -> Planner? { try traverse(redo: false) }
    @discardableResult public func redo() throws -> Planner? { try traverse(redo: true) }
    private func traverse(redo: Bool) throws -> Planner? {
        gate.lock(); defer { gate.unlock() }
        if !redo,
            let saved = try agentUndoOrdering.undoIfNewer(
                file: file, at: clock.now, calendar: calendar, hasLocalUndo: history.canUndo)
        {
            return saved
        }
        var saved: Planner?
        let transaction: ((inout Planner) -> Void) throws -> Void = { change in
            saved = try self.file.mutate { planner in
                let before = planner
                change(&planner)
                planner.stampTaskChanges(from: before, at: self.clock.now)
                return planner
            }
        }
        if redo { try history.redo(transaction: transaction) } else { try history.undo(transaction: transaction) }
        if saved != nil { agentUndoOrdering.traversed(redo: redo) }
        return saved
    }
}

extension PlannerEngine {
    mutating func deleteProject(_ id: UUID) throws {
        guard planner.projects.contains(where: { $0.id == id }) else { throw PlannerError("Project id not found.") }
        planner.projects.removeAll { $0.id == id }
        for i in planner.tasks.indices where planner.tasks[i].projectID == id { planner.tasks[i].projectID = nil }
    }
}
