import Foundation

/// A conditional, field-scoped inverse of a user edit, never a document snapshot.
/// Runtime, service links and caller identity are never restored; focus credit comes from the current ledger.
public struct PlannerEdit {
    private var changes: [(inout Planner) -> Void] = []
    public var isEmpty: Bool { changes.isEmpty }

    public init(before: Planner, after: Planner) {
        self.init(before: before, after: after, reversingRestoration: false)
    }

    fileprivate init(before: Planner, after: Planner, reversingRestoration: Bool) {
        for old in before.tasks {
            if let new = after.tasks.first(where: { $0.id == old.id }) {
                taskField(\.title, id: old.id, before: old, after: new)
                taskField(\.day, id: old.id, before: old, after: new)
                taskField(\.done, id: old.id, before: old, after: new)
                taskField(\.completedAt, id: old.id, before: old, after: new)
                taskField(\.remindAt, id: old.id, before: old, after: new)
                taskField(\.deadline, id: old.id, before: old, after: new)
                taskField(\.priority, id: old.id, before: old, after: new)
                taskField(\.projectID, id: old.id, before: old, after: new)
                taskField(\.notes, id: old.id, before: old, after: new)
                taskField(\.repeatRule, id: old.id, before: old, after: new)
                // Starting focus also remembers its duration; that bookkeeping is not an edit.
                if before.focus == after.focus || after.focus?.taskID != old.id {
                    taskField(\.minutes, id: old.id, before: old, after: new)
                }
                taskField(\.steps, id: old.id, before: old, after: new)
                taskField(\.carriedFrom, id: old.id, before: old, after: new)
                taskField(\.repeatedFrom, id: old.id, before: old, after: new)
                taskField(\.repeatAnchor, id: old.id, before: old, after: new)
                taskField(\.carryCount, id: old.id, before: old, after: new)
            } else {
                // Recreate only user content, not an old timer, service link or credit snapshot.
                let content = Self.content(of: old)
                let index = before.tasks.firstIndex { $0.id == old.id }!
                changes.append { planner in
                    guard !planner.tasks.contains(where: { $0.id == content.id }) else { return }
                    var restored = content
                    restored.focusedSeconds =
                        restored.unloggedFocusedSeconds
                        + planner.focusSegments.filter { $0.taskID == content.id }.reduce(0) {
                            $0 + $1.seconds
                        }
                    planner.tasks.insert(restored, at: min(index, planner.tasks.count))
                }
            }
        }
        for added in after.tasks where !before.tasks.contains(where: { $0.id == added.id }) {
            let content = Self.content(of: added)
            // Only an inverse made while applying history can remove a restored task
            // with existing focus. These values are conflict guards, never snapshots to restore.
            let expectedCredit = reversingRestoration ? added.focusedSeconds : 0
            let expectedLedger = reversingRestoration ? after.focusSegments.filter { $0.taskID == added.id } : []
            changes.append { planner in
                guard let i = planner.tasks.firstIndex(where: { $0.id == content.id }),
                    Self.content(of: planner.tasks[i]) == content,
                    planner.tasks[i].focusedSeconds == expectedCredit,
                    planner.focusSegments.filter({ $0.taskID == content.id }) == expectedLedger,
                    planner.focus?.taskID != content.id
                else { return }
                planner.tasks.remove(at: i)
            }
        }
        // Reorder only the original IDs and only if their relative order is still ours.
        let shared = Set(before.tasks.map(\.id)).intersection(after.tasks.map(\.id))
        let oldOrder = before.tasks.map(\.id).filter { shared.contains($0) }
        let newOrder = after.tasks.map(\.id).filter { shared.contains($0) }
        if oldOrder != newOrder {
            changes.append { planner in
                let slots = planner.tasks.indices.filter { shared.contains(planner.tasks[$0].id) }
                guard slots.map({ planner.tasks[$0].id }) == newOrder else { return }
                let tasks = Dictionary(uniqueKeysWithValues: slots.map { (planner.tasks[$0].id, planner.tasks[$0]) })
                for (slot, id) in zip(slots, oldOrder) { planner.tasks[slot] = tasks[id]! }
            }
        }
        for day in Set(before.notes.map(\.day) + after.notes.map(\.day)) {
            let old = before.notes.first { $0.day == day }
            let new = after.notes.first { $0.day == day }
            if old != new {
                changes.append { planner in
                    guard planner.notes.first(where: { $0.day == day }) == new else { return }
                    planner.notes.removeAll { $0.day == day }
                    if let old { planner.notes.append(old) }
                }
            }
        }
        for id in Set(before.projects.map(\.id) + after.projects.map(\.id)) {
            let old = before.projects.first { $0.id == id }
            let new = after.projects.first { $0.id == id }
            if old != new {
                changes.append { planner in
                    guard planner.projects.first(where: { $0.id == id }) == new else { return }
                    planner.projects.removeAll { $0.id == id }
                    if let old { planner.projects.append(old) }
                }
            }
        }
        field(\.preferences.resetHour, before: before, after: after)
        field(\.preferences.carryMode, before: before, after: after)
        field(\.preferences.defaultFocusMinutes, before: before, after: after)
        field(\.preferences.focusCompletionSound, before: before, after: after)
        field(\.preferences.notchTimerPlacement, before: before, after: after)
        field(\.preferences.workspaceTimerStyle, before: before, after: after)
        field(\.preferences.notchOpenTrigger, before: before, after: after)
        field(\.preferences.notchOnMonitors, before: before, after: after)
        field(\.preferences.showOnDisplay, before: before, after: after)
        field(\.preferences.remindersSync, before: before, after: after)
        field(\.preferences.ringOnPhone, before: before, after: after)
        field(\.preferences.sortWithAI, before: before, after: after)
        field(\.preferences.includeWeekendsInStreak, before: before, after: after)
        field(\.preferences.catchScreenshots, before: before, after: after)
        field(\.preferences.catchCopies, before: before, after: after)
        field(\.preferences.workspaceCardOrder, before: before, after: after)
        field(\.preferences.hiddenWorkspaceCards, before: before, after: after)
        field(\.preferences.hiddenCalendarIDs, before: before, after: after)
        field(\.preferences.welcomeCompleted, before: before, after: after)
        membership(\.dismissedOverdue, before: before, after: after)
        membership(\.repeatOccurrences, before: before, after: after)
        for id in before.completedCalendarEventIDs.symmetricDifference(after.completedCalendarEventIDs) {
            let old = before.completedCalendarEventIDs.contains(id)
            changes.append { planner in
                if old {
                    planner.completedCalendarEventIDs.insert(id)
                } else {
                    planner.completedCalendarEventIDs.remove(id)
                }
            }
        }
        for id in Set(before.completedCalendarEventDays.keys).union(after.completedCalendarEventDays.keys) {
            let old = before.completedCalendarEventDays[id], new = after.completedCalendarEventDays[id]
            if old != new {
                changes.append { planner in
                    if planner.completedCalendarEventDays[id] == new { planner.completedCalendarEventDays[id] = old }
                }
            }
        }
    }

    public func restore(in planner: inout Planner) {
        for change in changes { change(&planner) }
    }

    private mutating func field<V: Equatable>(_ key: WritableKeyPath<Planner, V>, before: Planner, after: Planner) {
        let old = before[keyPath: key], new = after[keyPath: key]
        guard old != new else { return }
        changes.append { planner in
            if planner[keyPath: key] == new { planner[keyPath: key] = old }
        }
    }

    private mutating func taskField<V: Equatable>(
        _ key: WritableKeyPath<PlanTask, V>, id: UUID, before: PlanTask, after: PlanTask
    ) {
        let old = before[keyPath: key], new = after[keyPath: key]
        guard old != new else { return }
        changes.append { planner in
            guard let i = planner.tasks.firstIndex(where: { $0.id == id }), planner.tasks[i][keyPath: key] == new else {
                return
            }
            planner.tasks[i][keyPath: key] = old
        }
    }

    private mutating func membership<V: Hashable>(_ key: WritableKeyPath<Planner, [V]>, before: Planner, after: Planner)
    {
        let old = Set(before[keyPath: key]), new = Set(after[keyPath: key])
        for item in old.symmetricDifference(new) {
            let wasPresent = old.contains(item)
            changes.append { planner in
                if wasPresent {
                    if !planner[keyPath: key].contains(item) { planner[keyPath: key].append(item) }
                } else {
                    planner[keyPath: key].removeAll { $0 == item }
                }
            }
        }
    }

    private static func content(of task: PlanTask) -> PlanTask {
        var content = task
        content.focusedSeconds = 0
        content.updatedAt = content.createdAt
        content.reminderLink = nil
        content.agentID = nil
        return content
    }
}

/// Stack transitions commit only after the caller's locked persistence succeeds.
public struct PlannerUndoHistory {
    private var undoStack: [PlannerEdit] = []
    private var redoStack: [PlannerEdit] = []
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public init() {}

    public mutating func record(before: Planner, after: Planner) {
        let edit = PlannerEdit(before: before, after: after)
        guard !edit.isEmpty else { return }
        undoStack.append(edit)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    public mutating func undo(transaction: (_ body: (inout Planner) -> Void) throws -> Void) rethrows {
        guard let edit = undoStack.last else { return }
        let inverse = try perform(edit, transaction: transaction)
        undoStack.removeLast()
        if let inverse { redoStack.append(inverse) }
    }

    public mutating func redo(transaction: (_ body: (inout Planner) -> Void) throws -> Void) rethrows {
        guard let edit = redoStack.last else { return }
        let inverse = try perform(edit, transaction: transaction)
        redoStack.removeLast()
        if let inverse { undoStack.append(inverse) }
    }

    private func perform(_ edit: PlannerEdit, transaction: (_ body: (inout Planner) -> Void) throws -> Void) rethrows
        -> PlannerEdit?
    {
        var inverse: PlannerEdit?
        try transaction { planner in
            let before = planner
            edit.restore(in: &planner)
            let delta = PlannerEdit(before: before, after: planner, reversingRestoration: true)
            if !delta.isEmpty { inverse = delta }
        }
        return inverse
    }
}
