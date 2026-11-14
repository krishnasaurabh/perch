import Foundation
import PlannerCore

public struct AgentToolResult: Sendable {
    public let text: String
    public let structuredContent: JSON

    public init(text: String, structuredContent: JSON) {
        self.text = text
        self.structuredContent = structuredContent
    }
}

extension AgentTools {
    func makeResult(text: String, name: String, args: JSON, before: Planner, engine: PlannerEngine) throws
        -> AgentToolResult
    {
        let after = engine.planner
        let beforeByID = Dictionary(uniqueKeysWithValues: before.tasks.map { ($0.id, $0) })
        let afterByID = Dictionary(uniqueKeysWithValues: after.tasks.map { ($0.id, $0) })
        let added = after.tasks.filter { beforeByID[$0.id] == nil }
        let removed = before.tasks.filter { afterByID[$0.id] == nil }
        var data: JSON

        switch name {
        case "add_tasks":
            data = ["tasks": .array(added.map { taskJSON($0, engine) })]
        case "list_tasks":
            let day = try DayRef.parse(
                args["date"]?.string, now: now(), resetHour: after.preferences.resetHour, calendar: calendar)
            data = taskList(engine.tasks(on: day), view: day == .inbox ? "inbox" : "day", date: day.key, engine: engine)
            if day.key == engine.today {
                data = adding(
                    [
                        "focus": focusJSON(after.focus),
                        "upcoming": .array(
                            upcoming(engine).map {
                                ["date": .string($0.key.raw), "count": .number(Double($0.value.count))]
                            }),
                        "inbox_count": .number(Double(engine.tasks(on: .inbox).count)),
                        "overdue_count": .number(Double(engine.overdue().count)),
                    ], to: data)
            }
        case "list_inbox":
            data = taskList(engine.tasks(on: .inbox), view: "inbox", date: nil, engine: engine)
        case "list_overdue":
            data = taskList(engine.overdue(), view: "overdue", date: nil, engine: engine)
        case "get_task":
            let reference = args["task"]?.string ?? args["task"]?.int.map(String.init) ?? ""
            let day = try DayRef.parse(
                args["date"]?.string, now: now(), resetHour: after.preferences.resetHour, calendar: calendar)
            let id = try TaskReferenceResolver.resolve(reference, in: after, on: day)
            data = ["task": taskJSON(try engine.task(id), engine)]
        case "delete_task":
            data = ["task": taskJSON(removed[0], engine)]
        case "complete_task", "reopen_task", "rename_task", "move_task", "update_task", "snooze_reminder":
            let reference = args["task"]?.string ?? args["task"]?.int.map(String.init) ?? ""
            let dateKey = name == "move_task" ? "from" : "date"
            let day = try DayRef.parse(
                args[dateKey]?.string, now: now(), resetHour: before.preferences.resetHour, calendar: calendar)
            let id = try TaskReferenceResolver.resolve(reference, in: before, on: day)
            guard let task = afterByID[id] else {
                throw PlannerError("Unable to identify the changed task in the tool result.")
            }
            data = ["task": taskJSON(task, engine)]
        case "start_timer", "pause_timer", "resume_timer", "stop_timer":
            data = ["focus": focusJSON(after.focus)]
        case "read_notepad", "write_notepad":
            let day = try DayRef.parse(
                args["date"]?.string, now: now(), resetHour: after.preferences.resetHour, calendar: calendar,
                allowInbox: false
            ).key!
            var fields: [String: JSON] = ["date": .string(day.raw), "text": .string(engine.notepad(on: day))]
            if name == "write_notepad" { fields["mode"] = .string(args["mode"]?.string ?? "append") }
            data = .object(fields)
        case "get_insights":
            let value = engine.insights()
            data = [
                "today": insightDay(value.today), "streak": .number(Double(value.streak)),
                "last_seven": .array(value.lastSeven.map(insightDay)),
                "previous_seven": .array(value.previousSeven.map(insightDay)),
                "peak_hours": .array(value.peakHours.map { .number(Double($0)) }),
                "all_time_completed": .number(Double(value.allTimeCompleted)),
                "all_time_focus_seconds": .number(value.allTimeFocusSeconds),
                "all_time_completed_calendar_events": .number(Double(value.allTimeCompletedCalendarEvents)),
            ]
        case "list_projects":
            data = [
                "projects": .array(
                    after.projects.map { project in
                        let open = after.tasks.filter {
                            $0.projectID == project.id && !$0.done && ($0.day == nil || $0.day! >= engine.today)
                        }.count
                        return [
                            "id": .string(project.id.uuidString.lowercased()), "name": .string(project.name),
                            "open_task_count": .number(Double(open)),
                        ]
                    })
            ]
        case "update_overdue":
            let action = args["action"]!.string!
            let references = args["tasks"]!.array!.compactMap(\.string)
            let beforeEngine = PlannerEngine(planner: before, now: now, calendar: calendar)
            let ids = try Self.resolveOverdueIDs(references, in: beforeEngine)
            let tasks: [PlanTask]
            switch action {
            case "carry": tasks = added
            case "dismiss": tasks = ids.compactMap { beforeByID[$0] }
            default: tasks = ids.compactMap { afterByID[$0] }
            }
            let destination = action == "carry" ? args["date"]?.string ?? "today" : nil
            let day = try DayRef.parse(
                destination, now: now(), resetHour: after.preferences.resetHour, calendar: calendar, allowInbox: false
            ).key
            data = [
                "action": .string(action), "date": day.map { .string($0.raw) } ?? .null,
                "tasks": .array(tasks.map { taskJSON($0, engine) }),
            ]
        default:
            throw MCPServer.MethodNotFound(name: name)
        }
        return AgentToolResult(text: text, structuredContent: adding(["content_trust": "untrusted"], to: data))
    }

    static func resolveOverdueIDs(_ references: [String], in engine: PlannerEngine) throws -> [UUID] {
        let eligible = engine.overdue()
        var ids: [UUID] = []
        for raw in references {
            let reference = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = reference.lowercased()
            let matches = eligible.filter { $0.id.uuidString.lowercased().hasPrefix(lower) }
            guard !reference.isEmpty, lower.count >= 6, matches.count == 1 else {
                throw PlannerError("Use a unique task id from list_overdue for each overdue task.")
            }
            guard !ids.contains(matches[0].id) else { throw PlannerError("Select each overdue task only once.") }
            ids.append(matches[0].id)
        }
        guard ids.count == references.count, !ids.isEmpty else {
            throw PlannerError("Select at least one overdue task id from list_overdue.")
        }
        return ids
    }

    private func adding(_ fields: [String: JSON], to object: JSON) -> JSON {
        guard case .object(var existing) = object else { return object }
        for (key, value) in fields { existing[key] = value }
        return .object(existing)
    }

    private func taskList(_ tasks: [PlanTask], view: String, date: DayKey?, engine: PlannerEngine) -> JSON {
        let overdueIDs = Set(engine.overdue().map(\.id))
        return [
            "view": .string(view), "date": date.map { .string($0.raw) } ?? .null,
            "today": .string(engine.today.raw),
            "tasks": .array(tasks.map { taskJSON($0, engine, overdueIDs: overdueIDs) }),
        ]
    }

    private func upcoming(_ engine: PlannerEngine) -> [(key: DayKey, value: [PlanTask])] {
        Dictionary(
            grouping: engine.planner.tasks.filter { ($0.day ?? engine.today) > engine.today && !$0.done },
            by: { $0.day! }
        )
        .sorted { $0.key < $1.key }.prefix(7).map { $0 }
    }

    private func timestamp(_ date: Date?) -> JSON {
        guard let date else { return .null }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .string(formatter.string(from: date))
    }

    func taskJSON(_ task: PlanTask, _ engine: PlannerEngine, overdueIDs: Set<UUID>? = nil) -> JSON {
        let project = engine.project(id: task.projectID)
        let projectJSON: JSON =
            project.map {
                ["id": .string($0.id.uuidString.lowercased()), "name": .string($0.name)]
            } ?? .null
        return [
            "id": .string(task.id.uuidString.lowercased()), "title": .string(task.title),
            "day": task.day.map { .string($0.raw) } ?? .null, "done": .bool(task.done),
            "completed_at": timestamp(task.completedAt), "remind_at": timestamp(task.remindAt),
            "start": timestamp(task.startAt),
            "deadline": task.deadline.map { .string($0.raw) } ?? .null,
            "priority": .string(task.priority.rawValue), "project": projectJSON,
            "notes": .string(task.notes), "repeat": task.repeatRule.map { .string($0.description) } ?? .null,
            "minutes": task.minutes.map { .number(Double($0)) } ?? .null,
            "steps": .array(
                task.steps.map {
                    [
                        "id": .string($0.id.uuidString.lowercased()), "title": .string($0.title),
                        "done": .bool($0.done),
                    ]
                }),
            "focused_seconds": .number(task.focusedSeconds),
            "carried_from": task.carriedFrom.map { .string($0.raw) } ?? .null,
            "overdue": .bool(overdueIDs?.contains(task.id) ?? engine.overdue().contains { $0.id == task.id }),
        ]
    }

    private func focusJSON(_ focus: FocusSession?) -> JSON {
        guard let focus else { return .null }
        return [
            "task_id": focus.taskID.map { .string($0.uuidString.lowercased()) } ?? .null,
            "state": .string(focus.state.rawValue),
            "limit_seconds": focus.limit.map { .number($0) } ?? .null,
            "elapsed_seconds": .number(focus.elapsed(at: now())),
            "remaining_seconds": focus.remaining(at: now()).map { .number($0) } ?? .null,
            "started_at": timestamp(focus.startedAt),
        ]
    }

    private func insightDay(_ day: Insights.Day) -> JSON {
        [
            "day": .string(day.day.raw), "planned": .number(Double(day.planned)),
            "completed": .number(Double(day.completed)), "focus_seconds": .number(day.focusSeconds),
            "completed_calendar_events": .number(Double(day.completedCalendarEvents)),
        ]
    }
}
