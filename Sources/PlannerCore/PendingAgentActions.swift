import Foundation

public enum AgentActionDecision: Sendable { case keep, undo }

public struct AgentTaskSummary: Codable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let day: DayKey?
    init(_ task: PlanTask) { id = task.id; title = task.title; day = task.day }
}

/// A request is not a deletion. Only a person's Keep action may apply it.
public struct PendingAgentAction: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let agentID: String
    public let task: PlanTask
    public let createdAt: Date
    public let expiresAt: Date
}

public struct AgentActionEvent: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case requested, applied, cancelled, expired, undone }
    public let id: UUID
    public let actionID: UUID
    public let sequence: Int
    public let kind: Kind
    public let agentID: String
    public let operation: String
    public let tasks: [AgentTaskSummary]
    public let occurredAt: Date
}

/// Only affected records are retained, not the whole document or its history.
struct AgentChangeSnapshot: Codable, Equatable, Sendable {
    var tasks: [PlanTask]
    var projects: [TaskProject]
    var notes: [QuickNote]
    var thoughts: [ParkedThought]
    var dismissed: [UUID]
    var repeats: [RepeatOccurrence]
    var focus: FocusSession?
    var taskOrder: [UUID]
    var thoughtOrder: [UUID]

    init(_ source: Planner, comparedTo other: Planner) {
        tasks = source.tasks.filter { task in other.tasks.first { $0.id == task.id } != task }
        projects = source.projects.filter { project in other.projects.first { $0.id == project.id } != project }
        notes = source.notes.filter { note in other.notes.first { $0.day == note.day } != note }
        thoughts = source.parkedThoughts.filter { thought in
            other.parkedThoughts.first { $0.id == thought.id } != thought
        }
        dismissed = source.dismissedOverdue.filter { !other.dismissedOverdue.contains($0) }
        repeats = source.repeatOccurrences.filter { !other.repeatOccurrences.contains($0) }
        focus = source.focus
        taskOrder = source.tasks.map(\.id)
        thoughtOrder = source.parkedThoughts.map(\.id)
    }

    var planner: Planner {
        var value = Planner()
        value.tasks = tasks; value.projects = projects; value.notes = notes; value.parkedThoughts = thoughts
        value.dismissedOverdue = dismissed; value.repeatOccurrences = repeats; value.focus = focus
        return value
    }
}

public struct AgentChange: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sequence: Int
    public let agentID: String
    public let operation: String
    public let tasks: [AgentTaskSummary]
    public let occurredAt: Date
    public private(set) var undoneAt: Date?
    let before: AgentChangeSnapshot
    let after: AgentChangeSnapshot

    fileprivate mutating func undo(in engine: inout PlannerEngine, at time: Date) {
        let originalTaskIDs = Set(engine.planner.tasks.map(\.id))
        let originalThoughtIDs = Set(engine.planner.parkedThoughts.map(\.id))
        let currentFocus = engine.planner.focus
        let focusChanged = before.focus != after.focus
        let mayRestoreFocus = focusChanged && Self.sameRun(currentFocus, after.focus)
        // Settle time earned since the agent's edit; undo never rewinds the focus ledger.
        if mayRestoreFocus { _ = engine.stopTimer() }
        PlannerEdit(before: before.planner, after: after.planner).restore(in: &engine.planner)
        // Deleted tasks retain their creator identity, which the general edit inverse omits.
        for old in before.tasks where !after.tasks.contains(where: { $0.id == old.id }) {
            if let index = engine.planner.tasks.firstIndex(where: { $0.id == old.id }) {
                engine.planner.tasks[index].agentID = old.agentID
            }
        }
        Self.positionRestored(&engine.planner.tasks, order: before.taskOrder, original: originalTaskIDs)
        Self.positionRestored(&engine.planner.parkedThoughts, order: before.thoughtOrder, original: originalThoughtIDs)
        if before.focus != after.focus {
            for old in before.tasks {
                guard let new = after.tasks.first(where: { $0.id == old.id }), old.minutes != new.minutes,
                    let index = engine.planner.tasks.firstIndex(where: { $0.id == old.id }),
                    engine.planner.tasks[index].minutes == new.minutes
                else { continue }
                engine.planner.tasks[index].minutes = old.minutes
            }
        }
        if mayRestoreFocus {
            var restored = before.focus
            if var session = restored {
                if let taskID = session.taskID,
                    !engine.planner.tasks.contains(where: { $0.id == taskID && !$0.done && $0.day == engine.today })
                {
                    restored = nil
                } else {
                    session.banked =
                        Self.sameIdentity(before.focus, currentFocus)
                        ? (currentFocus?.elapsed(at: time) ?? session.banked) : session.elapsed(at: occurredAt)
                    session.resumedAt = session.state == .running ? time : nil
                    restored = session
                }
            }
            engine.planner.focus = restored
        }
        undoneAt = time
    }

    private static func positionRestored<Item: Identifiable>(_ items: inout [Item], order: [UUID], original: Set<UUID>)
    where Item.ID == UUID {
        for (offset, id) in order.enumerated() where !original.contains(id) {
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            let item = items.remove(at: index)
            if let next = order.dropFirst(offset + 1).first(where: { next in items.contains { $0.id == next } }),
                let destination = items.firstIndex(where: { $0.id == next })
            {
                items.insert(item, at: destination)
            } else if let previous = order.prefix(offset).last(where: { previous in items.contains { $0.id == previous }
            }),
                let destination = items.firstIndex(where: { $0.id == previous })
            {
                items.insert(item, at: destination + 1)
            } else {
                items.append(item)
            }
        }
    }

    private static func sameIdentity(_ lhs: FocusSession?, _ rhs: FocusSession?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.startedAt == rhs.startedAt && lhs.taskID == rhs.taskID
    }

    private static func sameRun(_ lhs: FocusSession?, _ rhs: FocusSession?) -> Bool {
        sameIdentity(lhs, rhs) && lhs?.state == rhs?.state && lhs?.limit == rhs?.limit
    }
}

/// Persisted with the planner, under the same lock and atomic replacement as its edits.
/// The latest 100 changes are undoable; the event tail is bounded to 512 entries.
public struct AgentActionLedger: Codable, Equatable, Sendable {
    public private(set) var pending: [PendingAgentAction] = []
    public fileprivate(set) var changes: [AgentChange] = []
    public private(set) var events: [AgentActionEvent] = []
    public private(set) var sequence = 0
    public init() {}
    public var canUndo: Bool { changes.contains { $0.undoneAt == nil } }
    public var latestUndoable: AgentChange? { changes.last { $0.undoneAt == nil } }

    public func pending(at time: Date) -> [PendingAgentAction] { pending.filter { $0.expiresAt > time } }

    private enum Field: String, CodingKey { case agentActions }
    static func decodeField(from decoder: Decoder) throws -> Self {
        let container = try decoder.container(keyedBy: Field.self)
        return try container.decodeIfPresent(Self.self, forKey: .agentActions) ?? Self()
    }
    func encodeField(to encoder: Encoder) throws {
        guard sequence > 0 || !pending.isEmpty || !changes.isEmpty else { return }
        var container = encoder.container(keyedBy: Field.self)
        try container.encode(self, forKey: .agentActions)
    }

    fileprivate mutating func emit(
        _ kind: AgentActionEvent.Kind, id: UUID, agentID: String, operation: String,
        tasks: [AgentTaskSummary], at time: Date
    ) {
        sequence += 1
        events.append(
            AgentActionEvent(
                id: UUID(), actionID: id, sequence: sequence, kind: kind,
                agentID: agentID, operation: operation, tasks: tasks, occurredAt: time))
        if events.count > 512 { events.removeFirst(events.count - 512) }
    }

    fileprivate mutating func record(before: Planner, after: Planner, agentID: String, operation: String, at time: Date)
    {
        let old = AgentChangeSnapshot(before, comparedTo: after)
        let new = AgentChangeSnapshot(after, comparedTo: before)
        guard old != new else { return }
        let id = UUID()
        let ids = Set(new.tasks.map(\.id))
        let tasks = (new.tasks + old.tasks.filter { !ids.contains($0.id) }).map(AgentTaskSummary.init)
        emit(.applied, id: id, agentID: agentID, operation: operation, tasks: tasks, at: time)
        changes.append(
            AgentChange(
                id: id, sequence: sequence, agentID: agentID, operation: operation,
                tasks: tasks, occurredAt: time, before: old, after: new))
        if changes.count > 100 { changes.removeFirst(changes.count - 100) }
    }

    fileprivate mutating func request(_ task: PlanTask, agentID: String, at time: Date) throws -> PendingAgentAction {
        if let existing = pending.first(where: { $0.task.id == task.id && $0.agentID == agentID }) { return existing }
        guard pending.count < 100 else {
            throw PlannerError("There are too many pending agent requests. Answer them in Perch first.")
        }
        let action = PendingAgentAction(
            id: UUID(), agentID: agentID, task: task,
            createdAt: time, expiresAt: time.addingTimeInterval(10))
        pending.append(action)
        emit(
            .requested, id: action.id, agentID: agentID, operation: "delete_task", tasks: [AgentTaskSummary(task)],
            at: time)
        return action
    }

    fileprivate mutating func remove(_ action: PendingAgentAction, kind: AgentActionEvent.Kind, at time: Date) {
        pending.removeAll { $0.id == action.id }
        if kind != .applied {
            emit(
                kind, id: action.id, agentID: action.agentID, operation: "delete_task",
                tasks: [AgentTaskSummary(action.task)], at: time)
        }
    }

    fileprivate mutating func expire(at time: Date) {
        for action in pending where action.expiresAt <= time { remove(action, kind: .expired, at: time) }
    }
}

/// Recover each ledger record independently; malformed neighbors never erase valid history.
func recoverAgentActions(
    _ decoder: Decoder, _ planner: inout Planner, _ issues: inout [PlannerRecoveryIssue],
    _ kept: inout Int, _ rejected: inout Int, _ fields: inout Int
) throws {
    let recovery = try AgentActionRecovery(from: decoder)
    planner.agentActions = AgentActionLedger(recovering: recovery)
    issues += recovery.issues
    kept += recovery.pending.count + recovery.changes.count + recovery.events.count
    rejected += recovery.rejected
    fields += recovery.fields
}

extension AgentActionLedger {
    fileprivate init(recovering recovery: AgentActionRecovery) {
        pending = recovery.pending
        changes = recovery.changes
        events = recovery.events
        // A damaged counter must not cause later events to reuse surviving sequence numbers.
        sequence = max(recovery.sequence, changes.map(\.sequence).max() ?? 0, events.map(\.sequence).max() ?? 0)
    }
}

private struct AgentActionRecovery: Decodable {
    var pending: [PendingAgentAction] = []
    var changes: [AgentChange] = []
    var events: [AgentActionEvent] = []
    var sequence = 0
    var issues: [PlannerRecoveryIssue] = []
    var rejected = 0
    var fields = 0
    private enum Root: String, CodingKey { case agentActions }
    private enum Field: String, CodingKey { case pending, changes, events, sequence }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Root.self)
        guard root.contains(.agentActions), !(try root.decodeNil(forKey: .agentActions)) else { return }
        do {
            let container = try root.nestedContainer(keyedBy: Field.self, forKey: .agentActions)
            pending = records(PendingAgentAction.self, in: container, key: .pending)
            changes = records(AgentChange.self, in: container, key: .changes)
            events = records(AgentActionEvent.self, in: container, key: .events)
            do { sequence = try container.decode(Int.self, forKey: .sequence) } catch {
                record(error, fallback: "agentActions.sequence")
            }
        } catch { record(error, fallback: "agentActions") }
    }

    private mutating func records<Value: Decodable>(
        _ type: Value.Type, in container: KeyedDecodingContainer<Field>, key: Field
    ) -> [Value] {
        var values: [Value] = []
        do {
            var list = try container.nestedUnkeyedContainer(forKey: key)
            while !list.isAtEnd {
                let index = list.currentIndex
                let decoder = try list.superDecoder()
                do { values.append(try Value(from: decoder)) } catch {
                    record(error, fallback: "agentActions.\(key.rawValue)[\(index)]", isRecord: true)
                }
            }
        } catch { record(error, fallback: "agentActions.\(key.rawValue)") }
        return values
    }

    private mutating func record(_ error: Error, fallback: String, isRecord: Bool = false) {
        if isRecord { rejected += 1 } else { fields += 1 }
        let path: [CodingKey]
        let reason: String
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            path = context.codingPath + [key]; reason = "Required field is missing."
        case DecodingError.typeMismatch(_, let context):
            path = context.codingPath; reason = "Value has the wrong type."
        case DecodingError.valueNotFound(_, let context):
            path = context.codingPath; reason = "Required value is null."
        case DecodingError.dataCorrupted(let context):
            path = context.codingPath; reason = "Value is invalid or unrecognized."
        default:
            path = []; reason = "Record could not be decoded."
        }
        var location = ""
        for key in path {
            if let index = key.intValue {
                location += "[\(index)]"
            } else {
                location += (location.isEmpty ? "" : ".") + key.stringValue
            }
        }
        issues.append(PlannerRecoveryIssue(path: location.isEmpty ? fallback : location, reason: reason))
    }
}

extension PlannerCommands {
    /// Called only by the MCP boundary after it has checked the current stored permissions.
    public func recordAgentChange(from before: Planner, agentID: String, operation: String, at time: Date) throws {
        try withAgentEngine { engine in
            let after = engine.planner
            engine.planner.agentActions.record(
                before: before, after: after, agentID: agentID, operation: operation, at: time)
        }
    }

    public func requestAgentDeletion(_ id: UUID, agentID: String, at time: Date) throws -> PendingAgentAction {
        try withAgentEngine { engine in
            try Self.requireTaskPermission(engine.planner)
            // Validate the ordinary delete contract without applying any part of it.
            var probe = engine
            _ = try probe.delete(id, on: .day(engine.today))
            let task = try engine.task(id)
            engine.planner.agentActions.expire(at: time)
            return try engine.planner.agentActions.request(task, agentID: agentID, at: time)
        }
    }

    public func expireAgentActions(at time: Date) throws {
        try withAgentEngine { $0.planner.agentActions.expire(at: time) }
    }

    public func resolveAgentAction(_ id: UUID, decision: AgentActionDecision, at time: Date) throws {
        try withAgentEngine { engine in
            engine.planner.agentActions.expire(at: time)
            guard let action = engine.planner.agentActions.pending.first(where: { $0.id == id }) else { return }
            guard decision == .keep else {
                engine.planner.agentActions.remove(action, kind: .cancelled, at: time)
                return
            }
            // A later edit or permission change must never silently widen earlier consent.
            let current = engine.planner.tasks.first { $0.id == action.task.id }
            guard let current, Self.deletionContent(current) == Self.deletionContent(action.task),
                engine.planner.preferences.agentsCanEditTasks,
                engine.planner.focus?.taskID != current.id || engine.planner.focus?.state == .finished
                    || engine.planner.preferences.agentsCanControlTime
            else {
                engine.planner.agentActions.remove(action, kind: .cancelled, at: time)
                return
            }
            var probe = engine
            do { _ = try probe.delete(current.id, on: .day(engine.today)) } catch {
                engine.planner.agentActions.remove(action, kind: .cancelled, at: time)
                return
            }
            let before = engine.planner
            engine = probe
            engine.planner.agentActions.remove(action, kind: .applied, at: time)
            let after = engine.planner
            engine.planner.agentActions.record(
                before: before, after: after, agentID: action.agentID,
                operation: "delete_task", at: time)
        }
    }

    public func undoAgentChange(_ id: UUID, at time: Date) throws {
        try withAgentEngine { engine in
            guard
                let index = engine.planner.agentActions.changes.firstIndex(where: { $0.id == id && $0.undoneAt == nil })
            else { return }
            var change = engine.planner.agentActions.changes[index]
            change.undo(in: &engine, at: time)
            engine.planner.agentActions.changes[index] = change
            engine.planner.agentActions.emit(
                .undone, id: change.id, agentID: change.agentID,
                operation: change.operation, tasks: change.tasks, at: time)
        }
    }

    private static func requireTaskPermission(_ planner: Planner) throws {
        guard planner.preferences.agentsCanEditTasks else {
            throw PlannerError(
                "Add and edit tasks is off for agents. Your tasks are unchanged. Turn it on in Settings to allow this change."
            )
        }
    }

    private static func deletionContent(_ source: PlanTask) -> PlanTask {
        var task = source
        task.focusedSeconds = 0; task.unloggedFocusedSeconds = 0; task.updatedAt = task.createdAt
        task.reminderLink = nil
        return task
    }
}

extension PlannerCommandPipeline {
    @discardableResult
    public func resolveAgentAction(_ id: UUID, decision: AgentActionDecision) throws -> PlannerCommandResult<Void> {
        try perform(origin: .background) { try $0.resolveAgentAction(id, decision: decision, at: $0.read.now()) }
    }

    @discardableResult
    public func expireAgentActions(at time: Date) throws -> PlannerCommandResult<Void> {
        try perform(origin: .background) { try $0.expireAgentActions(at: time) }
    }

    @discardableResult
    public func undoAgentChange(_ id: UUID) throws -> PlannerCommandResult<Void> {
        try perform(origin: .background) { try $0.undoAgentChange(id, at: $0.read.now()) }
    }
}

/// Per-pipeline ordering keeps external edits ahead of the local undo step they followed.
/// The inverse itself is durable, so another process or a restarted app can apply it.
final class AgentUndoOrdering {
    private var undo: [Int] = []
    private var redo: [Int] = []
    private struct FileStamp: Equatable {
        let modified: Date?
        let size: UInt64?
        let inode: UInt64?
    }
    private var cachedStamp: FileStamp?
    private var cachedCanUndo = false

    func canUndo(file: PlannerFile) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.url.path) else { return false }
        let stamp = FileStamp(
            modified: attributes[.modificationDate] as? Date,
            size: attributes[.size] as? UInt64, inode: attributes[.systemFileNumber] as? UInt64)
        if stamp != cachedStamp {
            cachedCanUndo = (try? file.snapshot().agentActions.canUndo) == true
            cachedStamp = stamp
        }
        return cachedCanUndo
    }

    func record(before: Planner, after: Planner) {
        guard !PlannerEdit(before: before, after: after).isEmpty else { return }
        undo.append(after.agentActions.sequence)
        if undo.count > 100 { undo.removeFirst() }
        redo.removeAll()
    }

    func traversed(redo isRedo: Bool) {
        if isRedo {
            if let value = redo.popLast() { undo.append(value) }
        } else {
            if let value = undo.popLast() { redo.append(value) }
        }
    }

    func undoIfNewer(file: PlannerFile, at time: Date, calendar: Calendar, hasLocalUndo: Bool) throws -> Planner? {
        guard let latest = try file.snapshot().agentActions.latestUndoable,
            !hasLocalUndo || latest.sequence > (undo.last ?? 0)
        else { return nil }
        return try file.mutate { planner in
            guard let current = planner.agentActions.latestUndoable,
                !hasLocalUndo || current.sequence > (undo.last ?? 0)
            else { return planner }
            var engine = PlannerEngine(planner: planner, now: { time }, calendar: calendar)
            guard let index = engine.planner.agentActions.changes.firstIndex(where: { $0.id == current.id }) else {
                return planner
            }
            var change = engine.planner.agentActions.changes[index]
            let before = engine.planner
            change.undo(in: &engine, at: time)
            engine.planner.agentActions.changes[index] = change
            engine.planner.agentActions.emit(
                .undone, id: change.id, agentID: change.agentID,
                operation: change.operation, tasks: change.tasks, at: time)
            engine.planner.stampTaskChanges(from: before, at: time)
            planner = engine.planner
            return planner
        }
    }
}

/// The same stream works across MCP and app processes. Cancellation releases its polling task.
public enum AgentActionEvents {
    public static func stream(file: PlannerFile, after sequence: Int = 0) -> AsyncThrowingStream<
        AgentActionEvent, Error
    > {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(512)) { continuation in
            let task = Task.detached {
                var cursor = sequence
                let pipeline = PlannerCommandPipeline(file: file)
                do {
                    while !Task.isCancelled {
                        let snapshot = try file.snapshot()
                        if snapshot.agentActions.pending.contains(where: { $0.expiresAt <= Date() }) {
                            try pipeline.expireAgentActions(at: Date())
                        }
                        for event in try file.snapshot().agentActions.events where event.sequence > cursor {
                            continuation.yield(event)
                            cursor = event.sequence
                        }
                        try await Task.sleep(for: .milliseconds(250))
                    }
                    continuation.finish()
                } catch is CancellationError { continuation.finish() } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
