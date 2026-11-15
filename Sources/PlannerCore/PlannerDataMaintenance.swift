import Foundation

extension FinishedTaskRetention {
    /// Calendar days a finished task is kept, or nil to keep finished tasks forever.
    public var days: Int? { self == .never ? nil : rawValue }
}

extension PlannerEngine {
    /// Removes finished tasks whose completion day is strictly before `today - days`.
    /// Open tasks and the focused task are never removed. A repeating series always keeps
    /// at least one member so its schedule survives, and carry copies that still mark an
    /// earlier task as handled stay in place.
    @discardableResult
    mutating func pruneFinishedTasks() -> [PlanTask] {
        guard let days = planner.preferences.finishedTaskRetention.days else { return [] }
        let cutoff = today.adding(days: -days, calendar: calendar)
        let focusedID = planner.focus?.taskID
        let presentIDs = Set(planner.tasks.map(\.id))
        let expired = planner.tasks.filter { task in
            guard task.done, task.id != focusedID,
                let finished = task.completedAt.map(dayKey) ?? task.day, finished < cutoff
            else { return false }
            if let original = task.carriedTaskID, presentIDs.contains(original) { return false }
            if task.carriedTaskID == nil, task.carriedFrom != nil { return false }
            return true
        }
        var removeIDs = Set<UUID>()
        for task in expired {
            if task.repeatRule != nil {
                let survivors = planner.tasks.filter {
                    $0.repeatSeriesID == task.repeatSeriesID && $0.repeatRule != nil && $0.id != task.id
                        && !removeIDs.contains($0.id)
                }
                guard !survivors.isEmpty else { continue }
                // Pin the series anchor before removing a member it may have been derived from.
                preserveRepeatAnchor(of: task.id)
            }
            removeIDs.insert(task.id)
        }
        guard !removeIDs.isEmpty else { return [] }
        let removed = planner.tasks.filter { removeIDs.contains($0.id) }
        planner.tasks.removeAll { removeIDs.contains($0.id) }
        return removed
    }

    /// Clears all planner content and resets preferences. The storage stays valid and
    /// the edit is recorded like any other user command.
    /// Recovery backups are not touched, so this is not a secure deletion.
    mutating func eraseLocalPlanner() {
        // The running session and its whole history go together, so no live timer outlives its ledger.
        var empty = Planner()
        empty.version = planner.version
        empty.agentActions = planner.agentActions
        empty.agentActions.eraseKeepingSequence()
        planner = empty
    }

    /// Adds the tasks of a decoded planner document under fresh identities.
    /// Notes, parked thoughts, focus history and preferences of the source are ignored.
    mutating func importTasks(from source: Planner) throws -> [PlanTask] {
        guard !source.tasks.isEmpty else { throw PlannerError("The selected file has no tasks to import.") }
        var projectIDs: [UUID: UUID] = [:]
        for project in source.projects {
            if let same = planner.projects.first(where: { $0.id == project.id && $0.name == project.name }) {
                projectIDs[project.id] = same.id
            } else if let named = planner.projects.first(where: {
                $0.name.compare(project.name, options: .caseInsensitive) == .orderedSame
            }) {
                projectIDs[project.id] = named.id
            } else {
                var added = project
                if planner.projects.contains(where: { $0.id == project.id }) { added.id = UUID() }
                planner.projects.append(added)
                projectIDs[project.id] = added.id
            }
        }
        let taskIDs = Dictionary(uniqueKeysWithValues: source.tasks.map { ($0.id, UUID()) })
        var imported: [PlanTask] = []
        for original in source.tasks {
            var task = original
            task.title = task.title.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.title.isEmpty else { throw PlannerError("An imported task has no title.") }
            if let minutes = task.minutes, !(1...720).contains(minutes) {
                throw PlannerError("An imported task has a time limit outside 1 to 720 minutes.")
            }
            guard Set(task.steps.map(\.id)).count == task.steps.count,
                task.steps.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else {
                throw PlannerError("An imported task has duplicate or empty steps.")
            }
            task.id = taskIDs[original.id]!
            task.projectID = original.projectID.flatMap { projectIDs[$0] }
            task.repeatedFrom = original.repeatedFrom.flatMap { taskIDs[$0] }
            task.carriedTaskID = original.carriedTaskID.flatMap { taskIDs[$0] }
            task.parkedFrom = nil
            task.reminderLink = nil
            task.agentID = nil
            // Focus history is not imported, so imported tasks start without focus credit.
            task.focusedSeconds = 0
            task.unloggedFocusedSeconds = 0
            imported.append(task)
        }
        planner.tasks += imported
        for occurrence in source.repeatOccurrences {
            guard let series = taskIDs[occurrence.seriesID] else { continue }
            let mapped = RepeatOccurrence(seriesID: series, day: occurrence.day)
            if !planner.repeatOccurrences.contains(mapped) { planner.repeatOccurrences.append(mapped) }
        }
        return imported
    }
}

extension PlannerCommands {
    /// Adds tasks from planner JSON without replacing this planner or changing preferences.
    @discardableResult
    public func importTasks(from data: Data) throws -> [PlanTask] {
        let source: Planner
        do { source = try PlannerFile.decodeDocument(data) } catch let error as PlannerSchemaError {
            throw error
        } catch {
            throw PlannerError("The selected file is not a Perch planner export.")
        }
        return try withAgentEngine { engine in
            var candidate = engine
            let before = candidate.planner
            let added = try candidate.importTasks(from: source)
            candidate.planner.stampTaskChanges(from: before, at: candidate.now())
            engine = candidate
            let current = Dictionary(uniqueKeysWithValues: engine.planner.tasks.map { ($0.id, $0) })
            return added.map { current[$0.id] ?? $0 }
        }
    }
}
