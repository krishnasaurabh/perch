import Foundation
import PlannerCore

/// Read-only presentation of the notification owner's accounting for the current occurrence.
/// "Missed" means delivery was not confirmed; it does not prove the person missed an alert.
public enum NotchReminderPresentation {
    /// The newest unresolved occurrence outlives the transient reminder card. It is
    /// never inferred from elapsed time and never schedules or replays an OS alert.
    public static func missedTask(
        in planner: Planner, records: [String: ReminderRecord], now: Date, dismissed: Set<String> = []
    ) -> PlanTask? {
        planner.tasks.filter {
            isMissed(task: $0, records: records, now: now)
                && !dismissed.contains(ScheduledReminder(task: $0).id)
        }.sorted {
            if $0.remindAt != $1.remindAt { return $0.remindAt! > $1.remindAt! }
            return $0.id.uuidString < $1.id.uuidString
        }.first
    }

    public static func isMissed(task: PlanTask?, records: [String: ReminderRecord], now: Date) -> Bool {
        guard let task, !task.done, task.day != nil, let due = task.remindAt, due <= now else { return false }
        let request = ScheduledReminder(task: task)
        guard let record = records[request.id], record.date == due else { return false }
        return record.state == .missed
    }
}
