import Foundation
import PlannerCore

public enum TaskDetailsField: String, Hashable, Sendable {
    case title, day, reminder, deadline, recurrence, project, minutes, steps, form
}

/// A structured repeat editor. Invalid or incomplete choices never mean “stop repeating”.
public struct TaskRecurrenceDraft: Equatable, Sendable {
    public enum Frequency: String, CaseIterable, Sendable {
        case none = "None", daily = "Daily", weekdays = "Weekdays", weekly = "Weekly"
        case monthly = "Monthly", quarterly = "Quarterly", yearly = "Yearly", custom = "Custom"

        public var title: String {
            switch self {
            case .none: PerchL10n.text("None")
            case .daily: PerchL10n.text("Daily")
            case .weekdays: PerchL10n.text("Weekdays")
            case .weekly: PerchL10n.text("Weekly")
            case .monthly: PerchL10n.text("Monthly")
            case .quarterly: PerchL10n.text("Quarterly")
            case .yearly: PerchL10n.text("Yearly")
            case .custom: PerchL10n.text("Custom")
            }
        }
    }
    public var frequency: Frequency = .none
    public var interval = "1"
    public var unit: TaskRepeat.Unit = .day
    public var selectWeekdays = false
    public var weekdays: Set<Int> = []
    public var fromCompletion = false

    public init(_ rule: TaskRepeat? = nil) {
        guard let rule else { return }
        interval = String(rule.interval); unit = rule.unit
        weekdays = Set(rule.weekdays); selectWeekdays = !weekdays.isEmpty
        fromCompletion = rule.fromCompletion
        if rule.weekdaysOnly {
            frequency = .weekdays
        } else if rule.interval == 1 {
            switch rule.unit {
            case .day: frequency = .daily
            case .week: frequency = .weekly
            case .month: frequency = .monthly
            }
        } else if rule.unit == .month && rule.interval == 3 {
            frequency = .quarterly
        } else if rule.unit == .month && rule.interval == 12 {
            frequency = .yearly
        } else {
            frequency = .custom
        }
    }

    public func rule() throws -> TaskRepeat? {
        guard frequency != .none else { return nil }
        let unit: TaskRepeat.Unit
        let count: Int
        switch frequency {
        case .none: return nil
        case .daily, .weekdays: unit = .day; count = 1
        case .weekly: unit = .week; count = 1
        case .monthly: unit = .month; count = 1
        case .quarterly: unit = .month; count = 3
        case .yearly: unit = .month; count = 12
        case .custom:
            guard let value = Int(interval), (1...999).contains(value) else {
                throw PlannerError(PerchL10n.text("Enter a repeat interval from 1 to 999."))
            }
            unit = self.unit; count = value
        }
        let days = unit == .week && selectWeekdays ? weekdays.sorted() : []
        if unit == .week && selectWeekdays && (days.isEmpty || !days.allSatisfy({ (1...7).contains($0) })) {
            throw PlannerError(PerchL10n.text("Choose at least one weekday, or turn off specific weekdays."))
        }
        return TaskRepeat(
            unit: unit, interval: count, weekdays: days,
            weekdaysOnly: frequency == .weekdays, fromCompletion: fromCompletion)
    }
}

/// An isolated details transaction; cancelling discards this value without touching storage.
public struct TaskDetailsDraft: Equatable, Sendable {
    public let original: PlanTask
    public var title: String
    public var notes: String
    public var scheduled: Bool
    public var day: DayKey?
    public var hasReminder: Bool
    public var remindAt: Date?
    public var hasDeadline: Bool
    public var deadline: DayKey?
    public var recurrence: TaskRecurrenceDraft
    public var priority: TaskPriority
    public var projectID: UUID?
    public var minutes: Int
    public var steps: [Subtask]

    public init(task: PlanTask) {
        original = task; title = task.title; notes = task.notes
        scheduled = task.day != nil; day = task.day
        hasReminder = task.remindAt != nil; remindAt = task.remindAt
        hasDeadline = task.deadline != nil; deadline = task.deadline
        recurrence = TaskRecurrenceDraft(task.repeatRule)
        priority = task.priority; projectID = task.projectID
        minutes = task.minutes ?? 0; steps = task.steps
    }

    public var hasChanges: Bool { self != TaskDetailsDraft(task: original) }

    /// Preview a day change with the same wall-time and DST policy used by durable moves.
    public mutating func selectDay(_ day: DayKey, using engine: PlannerEngine) throws {
        if hasReminder, let remindAt {
            let time = engine.calendar.dateComponents([.hour, .minute], from: remindAt)
            let hour = time.hour ?? 0
            let text = String(
                format: "%d:%02d %@", hour % 12 == 0 ? 12 : hour % 12, time.minute ?? 0, hour < 12 ? "am" : "pm")
            self.remindAt = try engine.parseReminder(text, on: day)
        }
        scheduled = true
        self.day = day
    }

    public mutating func moveToInbox() {
        scheduled = false; day = nil; hasReminder = false; remindAt = nil
        recurrence = TaskRecurrenceDraft()
    }

    public func errors(today: DayKey, now: Date, projects: [TaskProject]) -> [TaskDetailsField: String] {
        var errors: [TaskDetailsField: String] = [:]
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors[.title] = PerchL10n.text("Enter a task title.")
        }
        if scheduled {
            if let day {
                if day < today { errors[.day] = PerchL10n.text("Choose today or a later day.") }
            } else {
                errors[.day] = PerchL10n.text("Choose a scheduled day, or use Inbox.")
            }
        }
        if hasReminder {
            if !scheduled {
                errors[.reminder] = PerchL10n.text("Schedule this task before adding a reminder.")
            } else if let remindAt {
                if remindAt != original.remindAt
                    && (original.done || !remindAt.timeIntervalSince1970.isFinite || remindAt <= now)
                {
                    errors[.reminder] = PerchL10n.text("Choose a future reminder for an open task.")
                }
            } else {
                errors[.reminder] = PerchL10n.text("Choose a reminder date and time, or select None.")
            }
        }
        if hasDeadline && deadline == nil {
            errors[.deadline] = PerchL10n.text("Choose a deadline, or select None.")
        }
        do {
            if try resolvedRepeatRule() != nil && !scheduled {
                errors[.recurrence] = PerchL10n.text("Schedule this task before adding a repeat.")
            }
        } catch { errors[.recurrence] = error.localizedDescription }
        if let projectID, !projects.contains(where: { $0.id == projectID }) {
            errors[.project] = PerchL10n.text("This project is no longer available. Choose another project or None.")
        }
        if !(0...720).contains(minutes) {
            errors[.minutes] = PerchL10n.text("Choose a time limit from 0 to 720 minutes.")
        }
        if Set(steps.map(\.id)).count != steps.count
            || steps.contains(where: { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        {
            errors[.steps] = PerchL10n.text("Each step needs a title and a distinct identity.")
        }
        return errors
    }

    /// Run inside a single PlannerCommandPipeline transaction. Runtime fields are re-read, never replayed.
    public func apply(using commands: PlannerCommands) throws {
        let current = try commands.task(original.id)
        if let day = current.day, day < commands.today {
            throw PlannerError(PerchL10n.text("Earlier days are read-only."))
        }
        // Focus accounting may advance while the sheet is open; it is not editable draft state.
        guard Self.editableFieldsEqual(current, original) else {
            throw PlannerError(
                PerchL10n.text(
                    "This task changed while you were editing. Cancel and reopen it to load the latest version."))
        }
        try applyValidated(using: commands)
    }

    private static func editableFieldsEqual(_ a: PlanTask, _ b: PlanTask) -> Bool {
        a.title == b.title && a.notes == b.notes && a.day == b.day && a.done == b.done
            && a.remindAt == b.remindAt && a.deadline == b.deadline && a.repeatRule == b.repeatRule
            && a.priority == b.priority && a.projectID == b.projectID && a.minutes == b.minutes && a.steps == b.steps
    }

    private func applyValidated(using commands: PlannerCommands) throws {
        let errors = errors(today: commands.today, now: commands.read.now(), projects: commands.planner.projects)
        if let field = TaskDetailsField.allValidationFields.first(where: { errors[$0] != nil }),
            let error = errors[field]
        {
            throw PlannerError(error)
        }
        for action in try actions() { try commands.execute(action) }
    }

    private func resolvedRepeatRule() throws -> TaskRepeat? {
        // Existing schedules may predate the editor's limits. Unrelated edits keep them verbatim.
        if recurrence == TaskRecurrenceDraft(original.repeatRule) { return original.repeatRule }
        return try recurrence.rule()
    }

    /// Ordered typed edits for the details transaction; runtime accounting is never copied into them.
    func actions() throws -> [PlannerAction] {
        var actions: [PlannerAction] = []
        let rule = try resolvedRepeatRule()
        // End the old series before moving into Inbox, where the move also clears its local rule.
        if rule == nil && original.repeatRule != nil { actions.append(.endRepeat(original.id)) }
        let destination = scheduled ? day : nil
        if destination != original.day {
            actions.append(.move(original.id, destination.map(DayRef.day) ?? .inbox))
        }
        if let rule, rule != original.repeatRule {
            var edit = TaskEdit(); edit.repeatRule = rule.description
            actions.append(.update(original.id, edit))
        }
        var changes = TaskChanges()
        if title != original.title { changes.title = .set(title) }
        if notes != original.notes { changes.notes = .set(notes) }
        if priority != original.priority { changes.priority = .set(priority) }
        if projectID != original.projectID { changes.projectID = .set(projectID) }
        if steps != original.steps { changes.steps = .set(steps) }
        if minutes != (original.minutes ?? 0) { changes.minutes = .set(minutes == 0 ? nil : minutes) }
        if hasReminder != (original.remindAt != nil) || remindAt != original.remindAt {
            changes.remindAt = .set(hasReminder ? remindAt : nil)
        }
        let deadline = hasDeadline ? deadline : nil
        if deadline != original.deadline { changes.deadline = .set(deadline) }
        actions.append(.editTask(original.id, changes))
        return actions
    }
}

extension TaskDetailsField {
    fileprivate static let allValidationFields: [Self] = [
        .title, .day, .reminder, .deadline, .recurrence, .project, .minutes, .steps,
    ]
}
