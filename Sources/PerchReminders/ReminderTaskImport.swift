import Foundation
import PlannerCore

/// Translate only representable fields through normal planner actions. This deliberately retains
/// the planner's rules: completion/reopening is for today, historical tasks are read-only, and
/// timed reminders must be in the future. Unsupported imports stop without partial mutation.
public enum ReminderTaskImport {
    public static func actions(
        task: PlanTask, fields: ReminderFields?, planner: Planner, now: Date,
        calendar: Calendar = .current
    ) throws -> [PlannerAction] {
        var actions: [PlannerAction] = []
        if let fields {
            guard let priority = [0: TaskPriority.none, 1: .high, 5: .medium, 9: .low][fields.priority] else {
                throw ReminderSyncError.stopped("The reminder priority is not representable in Perch.")
            }
            let schedule = try schedule(fields, resetHour: planner.preferences.resetHour, calendar: calendar)
            let expectedAlarm = planner.preferences.ringOnPhone ? schedule.time : nil
            guard fields.alarm == expectedAlarm else {
                throw ReminderSyncError.stopped(
                    "The reminder alarm does not match its due time and Perch alert setting.")
            }
            if task.done && !fields.completed { actions.append(.reopen(task.id)) }
            if task.day != schedule.day { actions.append(.move(task.id, schedule.day.map(DayRef.day) ?? .inbox)) }
            var edit = TaskChanges()
            if task.title != fields.title { edit.title = .set(fields.title) }
            if task.notes != (fields.notes ?? "") { edit.notes = .set(fields.notes ?? "") }
            if task.priority != priority { edit.priority = .set(priority) }
            // A move may have shifted the old reminder time. Set the target explicitly after it.
            if task.remindAt != schedule.time || task.day != schedule.day { edit.remindAt = .set(schedule.time) }
            if ReminderFields(task: task, ringOnPhone: planner.preferences.ringOnPhone, calendar: calendar) != fields {
                actions.append(.editTask(task.id, edit))
            }
            if !task.done && fields.completed { actions.append(.complete(task.id)) }
        } else {
            actions.append(.delete(task.id))
        }
        var probe = PlannerEngine(planner: planner, now: { now }, calendar: calendar)
        for action in actions { try probe.execute(action) }
        let actual = probe.planner.tasks.first { $0.id == task.id }.map {
            ReminderFields(task: $0, ringOnPhone: planner.preferences.ringOnPhone, calendar: calendar)
        }
        guard actual == fields else {
            throw ReminderSyncError.stopped(
                "The reminder cannot be represented exactly. Neither version was overwritten.")
        }
        return actions
    }

    private static func schedule(_ fields: ReminderFields, resetHour: Int, calendar: Calendar) throws -> (
        day: DayKey?, time: Date?
    ) {
        guard let due = fields.due else { return (nil, nil) }
        guard due.year != nil, due.month != nil, due.day != nil,
            (due.hour == nil) == (due.minute == nil)
        else { throw ReminderSyncError.stopped("The reminder has an incomplete due date.") }
        var civil = calendar
        if let zone = due.timeZone { civil.timeZone = zone }
        guard let date = civil.date(from: due),
            civil.component(.year, from: date) == due.year,
            civil.component(.month, from: date) == due.month,
            civil.component(.day, from: date) == due.day
        else { throw ReminderSyncError.stopped("The reminder has an invalid due date.") }
        if let hour = due.hour, let minute = due.minute {
            guard civil.component(.hour, from: date) == hour, civil.component(.minute, from: date) == minute else {
                throw ReminderSyncError.stopped("The reminder time does not exist in its time zone.")
            }
            return (DayKey(date, resetHour: resetHour, calendar: calendar), date)
        }
        return (DayKey(date, calendar: civil), nil)
    }
}
