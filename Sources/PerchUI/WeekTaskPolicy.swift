import Foundation
import PlannerCore

/// Presentation eligibility only. Commands revalidate against the locked latest
/// document, so stale chips cannot bypass the planner's identity or date rules.
public enum WeekTaskPolicy {
    public static func completionAction(for task: PlanTask, today: DayKey) -> PlannerAction? {
        guard task.day == today else { return nil }
        return task.done ? .reopen(task.id) : .complete(task.id)
    }

    public static func moveAction(
        payload: String, to destination: DayRef, tasks: [PlanTask], today: DayKey
    ) -> PlannerAction? {
        guard let id = UUID(uuidString: payload), let task = tasks.first(where: { $0.id == id }),
            !task.done, task.day.map({ $0 >= today }) ?? true,
            destination.key.map({ $0 >= today }) ?? true,
            task.day != destination.key
        else { return nil }
        return .move(id, destination)
    }
}
