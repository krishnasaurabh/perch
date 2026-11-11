import Foundation
import PlannerCore

/// Read-only presentation of the notification owner's accounting for the current occurrence.
/// "Missed" means delivery was not confirmed; it does not prove the person missed an alert.
public enum NotchReminderPresentation {
    public static func isMissed(task: PlanTask?, records: [String: ReminderRecord], now: Date) -> Bool {
        guard let task, !task.done, task.day != nil, let due = task.remindAt, due <= now else { return false }
        let request = ScheduledReminder(task: task)
        guard let record = records[request.id], record.date == due else { return false }
        return record.state == .missed
    }
}
