import Foundation

/// The planner tools agents see. Mutations use a locked read-modify-write; reads use an atomic snapshot.
public struct AgentTools {
    public let file: PlannerFile
    public let now: () -> Date
    public let calendar: Calendar

    public init(file: PlannerFile, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.file = file; self.now = now; self.calendar = calendar
    }

    public static let instructions = """
        Use Perch to manage tasks, notes and focus sessions. Start with list_tasks to get task ids. \
        Earlier days are history and cannot be edited. Supply dates as yyyy-MM-dd in the user's time zone. \
        add_tasks extracts scheduling details from titles unless literal is true. For example, \
        "water plants tomorrow at 6pm !high #home" sets a day, reminder, priority and project. \
        Repeats use phrases like "every tuesday"; deadlines use "due thursday"; timer limits use "for 25 min". \
        To change existing details, call update_task. Keep titles brief and start with an action.
        """

    // MARK: Schemas

    static func str(_ d: String) -> JSON { ["type": "string", "description": .string(d)] }
    static func int(_ d: String, range: ClosedRange<Int>) -> JSON {
        ["type": "integer", "description": .string(d),
         "minimum": .number(Double(range.lowerBound)), "maximum": .number(Double(range.upperBound))]
    }
    static let dayDesc = "Enter a yyyy-MM-dd date or use today, tomorrow, yesterday."
    static let taskRef = str("Task id returned by list_tasks, or matching title text.")

    static func tool(_ name: String, _ desc: String, _ props: [String: JSON] = [:], required: [String] = [], readOnly: Bool = false) -> JSON {
        [
            "name": .string(name), "description": .string(desc),
            "inputSchema": ["type": "object", "properties": .object(props), "required": .array(required.map { .string($0) })],
            "annotations": ["readOnlyHint": .bool(readOnly)],
        ]
    }

    public static let definitions: [JSON] = [
        tool("add_tasks",
             "Create tasks for today, a later date or inbox. Scheduling phrases in each title set its details; an explicit day in a title overrides date. New tasks go at the bottom of the list.",
             ["titles": ["type": "array", "items": ["type": "string"], "description": "Task text to capture. Supports dates, times, #project, !priority, repeats, due dates and durations such as \"for 25 min\"."],
              "date": str("Fallback day when a title has no date; omitted means today. Also accepts inbox. \(dayDesc)"),
              "literal": ["type": "boolean", "description": "Keep title text unchanged and skip scheduling-phrase parsing."]],
             required: ["titles"]),
        tool("list_tasks",
             "Read tasks and ids for a date or inbox, creating due repeat occurrences as needed. For today, includes timer status and a summary of later plans. Earlier dates can be viewed but not edited.",
             ["date": str("List this date or inbox; omitted means today. \(dayDesc)")]),
        tool("get_task",
             "Read a task's full details, including scheduling, progress, notes and steps. Earlier tasks can also be inspected.",
             ["task": taskRef, "date": str("Look for the task on this date; omitted means today.")], required: ["task"], readOnly: true),
        tool("complete_task", "Finish a task scheduled today and end its active focus session.", ["task": taskRef], required: ["task"]),
        tool("reopen_task", "Undo completion for a task scheduled today.", ["task": taskRef], required: ["task"]),
        tool("rename_task", "Give a task a different title. Earlier dates cannot be edited.",
             ["task": taskRef, "title": str("Replacement title text, on one line."), "date": str("Look for the task on this date; omitted means today. \(dayDesc)")],
             required: ["task", "title"]),
        tool("delete_task", "Delete a task unless it belongs to an earlier date.",
             ["task": taskRef, "date": str("Look for the task on this date or in inbox; omitted means today.")], required: ["task"]),
        tool("move_task",
             "Reschedule an open task between today, later dates and inbox. Inbox tasks have no scheduled day; earlier dates cannot be changed.",
             ["task": taskRef, "to": str("Destination date, or inbox to leave it unscheduled. \(dayDesc)"), "from": str("Current date or inbox; omitted means today.")],
             required: ["task", "to"]),
        tool("update_task",
             "Edit the supplied task fields and leave other fields unchanged. Supports scheduling, title, priority, project, notes, repeats, time limits and steps. Earlier dates cannot be edited.",
             ["task": taskRef, "date": str("Look for the task on this date; omitted means today."),
              "title": str("Replacement title text, on one line."),
              "remind_at": str("Reminder time, such as 18:15, 6:15 pm, 2026-12-01 18:15, \"in 15 minutes\" or \"tomorrow at 8\". A time alone uses the task date. Use none to clear."),
              "deadline": str("Due date in yyyy-MM-dd format, separate from the scheduled day. Use none to clear."),
              "priority": ["type": "string", "enum": ["low", "medium", "high", "none"]],
              "project": str("Assign a named project, creating it if needed. Use none to clear."),
              "notes": str("Replace all task notes with this text. Empty text clears the notes."),
              "repeat": str("Repeat rule: daily, weekdays, weekly, monthly, or e.g. \"every 2 weeks\", \"every tue, thu\", \"every! 4 days\". The ! variant counts from completion. Use none to disable."),
              "minutes": int("Set a 1–720 minute limit, or 0 to clear it.", range: 0...720),
              "steps": ["type": "array", "items": ["type": "string"], "description": "Replace all steps. Matching step titles retain their completion state."],
              "done_steps": ["type": "array", "items": ["type": "string"], "description": "Mark these existing step titles as complete."]],
             required: ["task"]),
        tool("snooze_reminder", "Schedule another reminder for a task after a short delay.",
             ["task": taskRef, "minutes": int("Delay in minutes; omitted means 5.", range: 1...1440)], required: ["task"]),
        tool("start_timer",
             "Begin a focus session, optionally for a task scheduled today. Replaces the active session. Minutes sets the countdown and task limit; otherwise uses the task limit or default timer setting.",
             ["task": str("Task id or title; omit for a standalone session."), "minutes": int("Run the countdown for 1–720 minutes.", range: 1...720)]),
        tool("pause_timer", "Hold the current focus session."),
        tool("resume_timer", "Continue a focus session that is on hold."),
        tool("stop_timer", "End the focus session and leave task completion unchanged."),
        tool("read_notepad", "Read the free-form notes saved for a date.",
             ["date": str("Note date; omitted means today. \(dayDesc)")], readOnly: true),
        tool("write_notepad", "Write daily notes by appending or replacing text. Earlier dates cannot be edited.",
             ["text": str("Note content, up to 20000 characters."), "mode": ["type": "string", "enum": ["append", "replace"], "description": "Use append to add a line (default), or replace to overwrite the notes."],
              "date": str("Note date; omitted means today. \(dayDesc)")], required: ["text"]),
        tool("get_insights",
             "Summarize task completion, focus time, streaks and busiest focus hours. Compare the last seven days with the preceding week.", readOnly: true),
        tool("list_projects", "List projects and count their open tasks in inbox, today and later dates.", readOnly: true),
    ]

    // MARK: Dispatch

    static func isReadOnly(_ name: String) -> Bool {
        definitions.first { $0["name"]?.string == name }?["annotations"]?["readOnlyHint"]?.bool ?? false
    }

    public func call(_ name: String, _ args: JSON, agentID: String? = nil) throws -> String {
        // Only omission selects a standalone timer. Validate supplied references before
        // acquiring the storage lock or loading data, which can create recovery files.
        if name == "start_timer", let value = args["task"] {
            guard let reference = value.string,
                  !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PlannerError("Invalid argument 'task': enter a non-empty task id or title, or omit it for a standalone session.")
            }
        }
        if Self.isReadOnly(name) {
            // Atomic writer replacement makes a single read a consistent snapshot. Do
            // not create a lock or a recovery copy while serving an advertised read.
            var p = Planner()
            if FileManager.default.fileExists(atPath: file.url.path) {
                let data = try Data(contentsOf: file.url)
                do { p = try PlannerFile.decoder.decode(Planner.self, from: data) }
                catch { throw PlannerError("Unable to load planner data.") }
            }
            return try dispatch(name, args, planner: &p, agentID: agentID)
        }
        return try file.mutate { p in
            try dispatch(name, args, planner: &p, agentID: agentID)
        }
    }

    private func dispatch(_ name: String, _ args: JSON, planner: inout Planner, agentID: String?) throws -> String {
        var engine = PlannerEngine(planner: planner, now: now, calendar: calendar)
        defer { planner = engine.planner }
        let resetHour = planner.preferences.resetHour
        let a = args
        func day(_ key: String, inbox: Bool = true) throws -> DayRef {
            try DayRef.parse(a[key]?.string, now: now(), resetHour: resetHour, calendar: calendar, allowInbox: inbox)
        }
        func task() throws -> String {
            guard let t = a["task"]?.string ?? a["task"]?.int.map(String.init), !t.isEmpty else { throw PlannerError("Identify the task by id from list_tasks or by title.") }
            return t
        }
        func minutes(in range: ClosedRange<Int>) throws -> Int? {
            guard let value = a["minutes"] else { return nil }
            guard let number = value.int, range.contains(number) else {
                let bounds = range.lowerBound == 0
                    ? "1 to \(range.upperBound), or 0 to clear the limit"
                    : "\(range.lowerBound) to \(range.upperBound)"
                throw PlannerError("Invalid argument 'minutes': enter an integer from \(bounds).")
            }
            return number
        }
        func edit<T>(_ body: (inout PlannerEngine) throws -> T) throws -> T { try body(&engine) }
        func read() throws -> PlannerEngine { engine }

        switch name {
        case "add_tasks":
            guard let titles = a["titles"]?.stringArray, !titles.isEmpty else { throw PlannerError("Add at least one task title with text.") }
            let d = a["date"] == nil ? nil : try day("date")
            let added = try edit { try $0.addTasks(titles, on: d, literal: a["literal"]?.bool ?? false, agentID: agentID) }
            let e = try read()
            return "Added \(added.count == 1 ? "1 task" : "\(added.count) tasks"):\n" + added.map { line($0, e) }.joined(separator: "\n")

        case "list_tasks":
            let d = try day("date")
            if let key = d.key { engine.applyRepeats(on: key) }
            let e = try read()
            let ts = e.tasks(on: d)
            var out: [String] = []
            switch d {
            case .inbox:
                if ts.isEmpty { return "Inbox has no tasks. Use someday or #inbox to add an unscheduled task." }
                out.append("Inbox (\(ts.count)):")
            case .day(let k):
                let label = k == e.today ? "Today, \(k)" : k < e.today ? "\(k) (past, read-only)" : "\(k)"
                out.append(ts.isEmpty ? "\(label): nothing planned." : "\(label): \(ts.filter(\.done).count)/\(ts.count) done")
            }
            out += ts.map { line($0, e) }
            if d.key == e.today {
                if let f = e.planner.focus, f.state != .finished {
                    let t = f.taskID.flatMap { id in e.planner.tasks.first { $0.id == id }?.title } ?? "no task"
                    let clock = f.remaining(at: now()).map { "\(TimerText.clock($0)) left" } ?? "\(TimerText.clock(f.elapsed(at: now()))) elapsed"
                    out.append("Focus timer: \(f.state.rawValue), \(clock), on \(t).")
                }
                let upcoming = Dictionary(grouping: e.planner.tasks.filter { ($0.day ?? e.today) > e.today && !$0.done }, by: { $0.day! })
                    .sorted { $0.key < $1.key }.prefix(7)
                if !upcoming.isEmpty {
                    out.append("Planned ahead: " + upcoming.map { "\($0.key) (\($0.value.count))" }.joined(separator: ", ") + ". Inspect a date with list_tasks for details.")
                }
                let inbox = e.tasks(on: .inbox).count
                if inbox > 0 { out.append("Inbox holds \(inbox) unscheduled tasks. Read them with list_tasks(date: inbox).") }
                let overdue = e.overdue().count
                if overdue > 0 { out.append("\(overdue) unfinished from earlier days.") }
            }
            return out.joined(separator: "\n")

        case "get_task":
            let e = try read()
            let i = try e.index(of: task(), on: e.resolved(try day("date")))
            return detail(e.planner.tasks[i], e)

        case "complete_task":
            let t = try edit { try $0.complete(try task()) }
            return "Done: \(t.title)."
        case "reopen_task":
            let t = try edit { try $0.reopen(try task()) }
            return "Reopened \(t.title)."
        case "rename_task":
            guard let title = a["title"]?.string else { throw PlannerError("Enter replacement title text.") }
            let t = try edit { try $0.rename(try task(), on: try day("date"), to: title) }
            return "Renamed it to \(t.title)."
        case "delete_task":
            let t = try edit { try $0.delete(try task(), on: try day("date")) }
            return "Deleted: \(t.title). Undo is available in Perch."
        case "move_task":
            guard a["to"]?.string != nil else { throw PlannerError("Set a destination date or use inbox.") }
            let t = try edit { try $0.move(try task(), from: try day("from"), to: try day("to")) }
            return t.day.map { "Moved \(t.title) to \($0)." } ?? "Unscheduled into inbox: \(t.title)."
        case "update_task":
            var ed = TaskEdit()
            ed.title = a["title"]?.string; ed.remindAt = a["remind_at"]?.string; ed.deadline = a["deadline"]?.string
            ed.priority = a["priority"]?.string; ed.project = a["project"]?.string; ed.notes = a["notes"]?.string
            ed.repeatRule = a["repeat"]?.string; ed.minutes = try minutes(in: 0...720)
            ed.steps = a["steps"]?.stringArray; ed.doneSteps = a["done_steps"]?.stringArray
            let t = try edit { try $0.update(try task(), on: try day("date"), ed) }
            return "Updated.\n" + detail(t, try read())
        case "snooze_reminder":
            let t = try edit { try $0.snooze(try task(), minutes: minutes(in: 1...1440) ?? 5) }
            return "Snoozed \(t.title) until \(hm(t.remindAt!))."
        case "start_timer":
            let s = try edit { try $0.startTimer(task: a["task"]?.string, minutes: minutes(in: 1...720)) }
            let e = try read()
            let t = s.taskID.flatMap { id in e.planner.tasks.first { $0.id == id }?.title }
            return "Started the timer\(t.map { " on \($0)" } ?? "")" + (s.limit.flatMap { Int(exactly: ($0 / 60).rounded(.towardZero)) }.map { ", \($0) minutes." } ?? ".")
        case "pause_timer": try edit { try $0.pauseTimer() }; return "Focus session paused."
        case "resume_timer": try edit { try $0.resumeTimer() }; return "Focus session resumed."
        case "stop_timer":
            let had = try read().planner.focus.map { $0.state != .finished } ?? false
            guard had else { throw PlannerError("Start a focus session first.") }
            try edit { _ = $0.stopTimer() }
            return "Focus ended; the task was not completed."
        case "read_notepad":
            let d = try day("date", inbox: false).key!
            let text = try read().notepad(on: d)
            return text.isEmpty ? "No notes saved for \(d)." : "Notepad, \(d):\n\(text)"
        case "write_notepad":
            guard let text = a["text"]?.string, !text.isEmpty else { throw PlannerError("Enter note text using 20000 characters or fewer.") }
            let d = try day("date", inbox: false).key!
            let mode = a["mode"]?.string ?? "append"
            try edit { try $0.writeNotepad(on: d, text: text, mode: mode) }
            return mode == "replace" ? "Notes overwritten for \(d)." : "Notes appended for \(d)."
        case "get_insights":
            let i = try read().insights()
            let lastFocus = i.lastSeven.reduce(0) { $0 + $1.focusSeconds }, prevFocus = i.previousSeven.reduce(0) { $0 + $1.focusSeconds }
            let lastDone = i.lastSeven.reduce(0) { $0 + $1.completed }, prevDone = i.previousSeven.reduce(0) { $0 + $1.completed }
            var out = [
                "Today: \(i.today.completed)/\(i.today.planned) tasks done, \(TimerText.short(i.today.focusSeconds)) focused.",
                "Calendar events completed in Perch: \(i.today.completedCalendarEvents) today, \(i.allTimeCompletedCalendarEvents) all time.",
                "Streak: \(i.streak) day\(i.streak == 1 ? "" : "s").",
                "Last 7 days: \(lastDone) tasks done (\(prevDone) in the prior week), \(TimerText.short(lastFocus)) focused (\(TimerText.short(prevFocus)) in the prior week).",
            ]
            out.append(i.peakHours.isEmpty ? "Focus history is empty." : "Peak hours: " + i.peakHours.map { "\($0):00" }.joined(separator: ", ") + ".")
            out.append("By day: " + i.lastSeven.map { "\($0.day) \($0.completed)/\($0.planned)" }.joined(separator: ", "))
            return out.joined(separator: "\n")
        case "list_projects":
            let e = try read()
            if e.planner.projects.isEmpty { return "No projects to list. Assign a project to a task to create one." }
            return e.planner.projects.map { p in
                let open = e.planner.tasks.filter { $0.projectID == p.id && !$0.done && ($0.day == nil || $0.day! >= e.today) }.count
                return "#\(p.name): \(open) open"
            }.joined(separator: "\n")
        default:
            throw MCPServer.MethodNotFound(name: name)
        }
    }

    // MARK: Formatting

    func hm(_ d: Date) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    func line(_ t: PlanTask, _ e: PlannerEngine) -> String {
        var bits = ["[\(t.done ? "x" : " ")] \(t.title)", "id \(t.id.uuidString.prefix(8).lowercased())"]
        if let d = t.day, d != e.today { bits.append(d.raw) }
        if t.day == nil { bits.append("inbox") }
        if let r = t.remindAt { bits.append("remind \(hm(r))") }
        if t.priority != .none { bits.append("\(t.priority.rawValue) priority") }
        if let p = e.project(id: t.projectID) { bits.append("#\(p.name)") }
        if let r = t.repeatRule { bits.append(r.description) }
        if let dl = t.deadline { bits.append("due \(dl)") }
        if let m = t.minutes { bits.append("\(m) min") }
        if !t.steps.isEmpty { bits.append("steps \(t.steps.filter(\.done).count)/\(t.steps.count)") }
        return "- " + bits.joined(separator: " · ")
    }

    func detail(_ t: PlanTask, _ e: PlannerEngine) -> String {
        var out = ["\(t.title) (id \(t.id.uuidString.prefix(8).lowercased()))",
                   "Day: \(t.day?.raw ?? "Inbox")", "Done: \(t.done ? "yes" : "no")"]
        if let r = t.remindAt { out.append("Reminder: \(DayKey(r, calendar: calendar)) \(hm(r))") }
        if let d = t.deadline { out.append("Deadline: \(d)") }
        if t.priority != .none { out.append("Priority: \(t.priority.rawValue)") }
        if let p = e.project(id: t.projectID) { out.append("Project: \(p.name)") }
        if let r = t.repeatRule { out.append("Repeat: \(r.description)") }
        if let m = t.minutes { out.append("Time limit: \(m) min") }
        if t.focusedSeconds > 0 { out.append("Focused: \(TimerText.short(t.focusedSeconds))") }
        if !t.steps.isEmpty { out.append("Steps:\n" + t.steps.map { "  [\($0.done ? "x" : " ")] \($0.title)" }.joined(separator: "\n")) }
        if !t.notes.isEmpty { out.append("Notes:\n\(t.notes)") }
        return out.joined(separator: "\n")
    }
}
