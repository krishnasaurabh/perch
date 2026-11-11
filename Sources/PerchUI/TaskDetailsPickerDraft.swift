import Foundation
import PlannerCore

/// Binds reusable picker drafts to the existing details transaction. Nothing is written until Save.
public struct TaskDetailsPickerDraft: Equatable, Sendable {
    public var details: TaskDetailsDraft
    public private(set) var scheduledDate: DateFieldDraft
    public var deadline: DateFieldDraft
    public var repeatRule: RepeatPickerDraft

    public init(task: PlanTask, today: DayKey, calendar: Calendar = .current) {
        details = TaskDetailsDraft(task: task)
        scheduledDate = DateFieldDraft(original: task.day, today: today, pastDays: .reject)
        deadline = DateFieldDraft(original: task.deadline, today: today)
        repeatRule = RepeatPickerDraft(task: task, calendar: calendar)
    }

    public var hasChanges: Bool {
        details.hasChanges || scheduledDate.hasChanges || deadline.hasChanges || repeatRule.hasChanges
    }

    /// Preserve reminder wall time through the same DST policy as a durable move.
    /// Invalid text stays visible, but cannot replace a valid schedule or reach storage.
    public mutating func setScheduledDate(_ value: DateFieldDraft, using engine: PlannerEngine) throws {
        var next = self
        next.scheduledDate = value
        switch value.entry {
        case .day(let day):
            try next.details.selectDay(day, using: engine)
            next.repeatRule.setAnchor(day)
        case .none:
            next.details.moveToInbox()
            next.repeatRule.select(.none)
            next.repeatRule.setAnchor(nil)
        case .invalid:
            next.repeatRule.setAnchor(nil)
        }
        self = next
    }

    /// The reminder can change the logical day, so update both pickers immediately.
    public mutating func setReminder(_ date: Date?, using engine: PlannerEngine) {
        details.hasReminder = date != nil
        details.remindAt = date
        if let date {
            let day = engine.dayKey(date)
            details.scheduled = true
            details.day = day
            scheduledDate.type(day.raw)
            repeatRule.setAnchor(day)
        }
    }

    public func errors(today: DayKey, now: Date, projects: [TaskProject]) -> [TaskDetailsField: String] {
        var errors = proposedDetails.errors(today: today, now: now, projects: projects)
        if let issue = scheduledDate.issue, issue.severity == .error { errors[.day] = issue.message }
        if let issue = deadline.issue, issue.severity == .error { errors[.deadline] = issue.message }
        var repeatDraft = repeatRule
        if repeatDraft.commit() == nil { errors[.recurrence] = repeatDraft.issue?.message }
        return errors
    }

    public func validatedDetails(today: DayKey, now: Date, projects: [TaskProject]) throws -> TaskDetailsDraft {
        let errors = errors(today: today, now: now, projects: projects)
        let order: [TaskDetailsField] = [.title, .day, .reminder, .deadline, .recurrence, .project, .minutes, .steps]
        if let message = order.compactMap({ errors[$0] }).first { throw PlannerError(message) }
        return proposedDetails
    }

    /// Called once inside the owner's command-pipeline transaction, retaining its conflict checks.
    public func apply(using commands: PlannerCommands) throws {
        let transaction = try validatedDetails(
            today: commands.today, now: commands.read.now(), projects: commands.planner.projects)
        try transaction.apply(using: commands)
    }

    private var proposedDetails: TaskDetailsDraft {
        var value = details
        switch scheduledDate.entry {
        case .day(let day): value.scheduled = true; value.day = day
        case .none: value.moveToInbox()
        case .invalid: break
        }
        switch deadline.entry {
        case .day(let day): value.hasDeadline = true; value.deadline = day
        case .none: value.hasDeadline = false; value.deadline = nil
        case .invalid: break
        }
        var repeatDraft = repeatRule
        switch repeatDraft.commit() {
        case .set(let rule): value.recurrence = TaskRecurrenceDraft(rule)
        case .cleared: value.recurrence = TaskRecurrenceDraft()
        case .unchanged, nil: value.recurrence = TaskRecurrenceDraft(details.original.repeatRule)
        }
        return value
    }
}
