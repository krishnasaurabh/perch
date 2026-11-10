import Foundation

extension PlanTask {
    /// A repeat is a fresh occurrence, not a copy of runtime or service state.
    func repeatInstance(on day: DayKey, anchor: DayKey?, at time: Date, reminder: Date?) -> PlanTask {
        PlanTask(
            title: title, day: day, createdAt: time, remindAt: reminder, deadline: deadline,
            priority: priority, projectID: projectID, notes: notes, repeatRule: repeatRule, minutes: minutes,
            steps: steps.map { Subtask(title: $0.title) }, repeatedFrom: repeatSeriesID, repeatAnchor: anchor)
    }

    /// Carry retains unfinished content and checklist progress, with fresh instance IDs.
    func carryInstance(to day: DayKey, from source: DayKey, at time: Date) -> PlanTask {
        PlanTask(
            title: title, day: day, createdAt: time, deadline: deadline,
            priority: priority, projectID: projectID, notes: notes, repeatRule: repeatRule, minutes: minutes,
            steps: steps.map { Subtask(title: $0.title, done: $0.done) }, carriedFrom: source,
            repeatedFrom: repeatRule == nil ? nil : repeatSeriesID, carryCount: carryCount + 1,
            repeatAnchor: repeatAnchor)
    }
}

extension Planner {
    /// Timestamps describe actual changes, not a read, serialization or a no-op command.
    mutating func stampTaskChanges(from before: Planner, at time: Date) {
        guard tasks != before.tasks else { return }
        let previous = Dictionary(before.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in tasks.indices {
            guard let old = previous[tasks[index].id] else {
                tasks[index].updatedAt = max(time, tasks[index].updatedAt)
                continue
            }
            var candidate = tasks[index]
            candidate.updatedAt = old.updatedAt
            if candidate != old { tasks[index].updatedAt = max(time, old.updatedAt) }
        }
    }
}
