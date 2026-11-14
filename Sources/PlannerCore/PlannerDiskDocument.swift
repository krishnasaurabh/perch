import Foundation

/// Explicit disk task schema. Adding a domain field does not silently change this format.
struct TaskDiskRecord: Codable {
    var id: UUID
    var title: String
    var day: DayKey?
    var done: Bool
    var completedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var unloggedFocusedSeconds: Double
    var startAt: Date?
    var remindAt: Date?
    var deadline: DayKey?
    var priority: TaskPriority
    var projectID: UUID?
    var notes: String
    var repeatRule: TaskRepeat?
    var minutes: Int?
    var steps: [Subtask]
    var focusedSeconds: Double
    var carriedFrom: DayKey?
    var carriedTaskID: UUID?
    var parkedFrom: UUID?
    var reminderLink: String?
    var repeatedFrom: UUID?
    var repeatAnchor: DayKey?
    var carryCount: Int
    var agentID: String?
    init(_ task: PlanTask) {
        id = task.id
        title = task.title
        day = task.day
        done = task.done
        completedAt = task.completedAt
        createdAt = task.createdAt
        updatedAt = task.updatedAt
        unloggedFocusedSeconds = task.unloggedFocusedSeconds
        startAt = task.startAt
        remindAt = task.remindAt
        deadline = task.deadline
        priority = task.priority
        projectID = task.projectID
        notes = task.notes
        repeatRule = task.repeatRule
        minutes = task.minutes
        steps = task.steps
        focusedSeconds = task.focusedSeconds
        carriedFrom = task.carriedFrom
        carriedTaskID = task.carriedTaskID
        parkedFrom = task.parkedFrom
        reminderLink = task.reminderLink
        repeatedFrom = task.repeatedFrom
        repeatAnchor = task.repeatAnchor
        carryCount = task.carryCount
        agentID = task.agentID
    }
    var task: PlanTask {
        var value = PlanTask(
            id: id, title: title, day: day, done: done, completedAt: completedAt,
            createdAt: createdAt, remindAt: remindAt, deadline: deadline, priority: priority,
            projectID: projectID, notes: notes, repeatRule: repeatRule, minutes: minutes, steps: steps,
            focusedSeconds: focusedSeconds, carriedFrom: carriedFrom, reminderLink: reminderLink,
            repeatedFrom: repeatedFrom, carryCount: carryCount, agentID: agentID, repeatAnchor: repeatAnchor,
            updatedAt: updatedAt, unloggedFocusedSeconds: unloggedFocusedSeconds, startAt: startAt,
            carriedTaskID: carriedTaskID, parkedFrom: parkedFrom)
        // The initializer chooses an anchor for new tasks; decoding must preserve an absent legacy anchor.
        value.repeatAnchor = repeatAnchor
        return value
    }
}

private struct FocusIntervalIdentity: Hashable {
    let taskID: UUID?
    let start: Date
    let end: Date
    init(_ segment: FocusSegment) { taskID = segment.taskID; start = segment.start; end = segment.end }
}

/// Disk versioning is independent of the version-1 portable export and undo models.
struct PlannerDiskDocument: Codable {
    static let currentVersion = 2
    var planner: Planner
    var sourceVersion: Int
    init(_ planner: Planner) throws {
        guard planner.version == Planner.currentVersion else { throw PlannerSchemaError(version: planner.version) }
        self.planner = planner; sourceVersion = Self.currentVersion
    }
    enum Keys: String, CodingKey {
        case version, tasks, taskOrder, projects, notes, parkedThoughts, notepadMigrationComplete, focusSegments,
            focusHistory, focusRecentIndices, focusLog,
            focus
        case dismissedOverdue, repeatOccurrences, completedCalendarEventIDs, completedCalendarEventDays, preferences
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        sourceVersion = try c.decodeMissing(Int.self, forKey: .version, default: 1)
        guard (1...Self.currentVersion).contains(sourceVersion) else {
            throw PlannerSchemaError(version: sourceVersion)
        }
        if sourceVersion == 1 {
            planner = try Planner(from: decoder)
            // Some older exports used focusLog. Preserve both collections, avoiding exact duplicates.
            if c.contains(.focusLog) {
                var positions = Dictionary(
                    planner.focusSegments.enumerated().map {
                        (FocusIntervalIdentity($0.element), $0.offset)
                    }, uniquingKeysWith: { first, _ in first })
                for segment in try c.decode([FocusSegment].self, forKey: .focusLog) {
                    let key = FocusIntervalIdentity(segment)
                    if let index = positions[key] {
                        // Conflicting sync metadata must retain the pending record, not double its credit.
                        planner.focusSegments[index].isSynced =
                            planner.focusSegments[index].isSynced && segment.isSynced
                    } else {
                        positions[key] = planner.focusSegments.count
                        planner.focusSegments.append(segment)
                    }
                }
            }
            reconcileLegacy()
        } else {
            planner = Planner()
            planner.tasks = try c.decode([TaskDiskRecord].self, forKey: .tasks).map(\.task)
            planner.projects = try c.decode([TaskProject].self, forKey: .projects)
            planner.notes = try c.decode([QuickNote].self, forKey: .notes)
            planner.parkedThoughts = try c.decodeMissing([ParkedThought].self, forKey: .parkedThoughts, default: [])
            planner.notepadMigrationComplete = try c.decodeMissing(
                Bool.self, forKey: .notepadMigrationComplete, default: false)
            planner.migrateNotepad()
            let archive = try c.decode([PackedFocusHistory].self, forKey: .focusHistory)
            let recent = try c.decode([FocusSegment].self, forKey: .focusSegments)
            let indices = try c.decode([Int].self, forKey: .focusRecentIndices)
            planner.focusSegments = try FocusHistoryStorage.restore(archive: archive, recent: recent, indices: indices)
            planner.focus = try c.decodeIfPresent(FocusSession.self, forKey: .focus)
            planner.dismissedOverdue = try c.decode([UUID].self, forKey: .dismissedOverdue)
            planner.repeatOccurrences = try c.decode([RepeatOccurrence].self, forKey: .repeatOccurrences)
            planner.completedCalendarEventIDs = Set(try c.decode([String].self, forKey: .completedCalendarEventIDs))
            planner.completedCalendarEventDays = try c.decode(
                [String: DayKey].self, forKey: .completedCalendarEventDays)
            planner.preferences = try c.decode(Preferences.self, forKey: .preferences)
        }
        guard Set(planner.parkedThoughts.map(\.id)).count == planner.parkedThoughts.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .parkedThoughts, in: c, debugDescription: "Duplicate thought identity.")
        }
        let order = try c.decodeMissing([UUID].self, forKey: .taskOrder, default: planner.tasks.map(\.id))
        guard Set(order).count == order.count, Set(planner.tasks.map(\.id)).count == planner.tasks.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .taskOrder, in: c, debugDescription: "Duplicate task identity or order entry.")
        }
        let indices = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        // Keep existing order; new/unlisted records follow in their original physical order.
        planner.tasks = planner.tasks.enumerated().sorted {
            (indices[$0.element.id] ?? order.count + $0.offset) < (indices[$1.element.id] ?? order.count + $1.offset)
        }.map(\.element)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(planner.tasks.map(TaskDiskRecord.init), forKey: .tasks)
        try c.encode(planner.tasks.map(\.id), forKey: .taskOrder)
        try c.encode(planner.projects, forKey: .projects)
        try c.encode(planner.notes, forKey: .notes)
        try c.encode(planner.parkedThoughts, forKey: .parkedThoughts)
        try c.encode(planner.notepadMigrationComplete, forKey: .notepadMigrationComplete)
        let history = FocusHistoryStorage(planner.focusSegments, current: planner.focus)
        try c.encode(history.recent, forKey: .focusSegments)
        try c.encode(history.recentIndices, forKey: .focusRecentIndices)
        try c.encode(history.archive, forKey: .focusHistory)
        try c.encodeIfPresent(planner.focus, forKey: .focus)
        try c.encode(planner.dismissedOverdue, forKey: .dismissedOverdue)
        try c.encode(planner.repeatOccurrences, forKey: .repeatOccurrences)
        try c.encode(planner.completedCalendarEventIDs.sorted(), forKey: .completedCalendarEventIDs)
        try c.encode(planner.completedCalendarEventDays, forKey: .completedCalendarEventDays)
        try c.encode(SharedPlannerPreferences(planner.preferences), forKey: .preferences)
    }
    private mutating func reconcileLegacy() {
        let credits = Dictionary(grouping: planner.focusSegments, by: \.taskID).mapValues {
            $0.reduce(0) { $0 + max(0, $1.seconds) }
        }
        for i in planner.tasks.indices {
            if planner.tasks[i].completedAt != nil { planner.tasks[i].done = true }
            let recorded = credits[planner.tasks[i].id] ?? 0
            let total = max(recorded, planner.tasks[i].focusedSeconds)
            planner.tasks[i].unloggedFocusedSeconds = max(planner.tasks[i].unloggedFocusedSeconds, total - recorded)
            planner.tasks[i].focusedSeconds = recorded + planner.tasks[i].unloggedFocusedSeconds
        }
        // A historical completion day is stronger evidence than a missing redundant membership.
        planner.completedCalendarEventIDs.formUnion(planner.completedCalendarEventDays.keys)
    }
}
