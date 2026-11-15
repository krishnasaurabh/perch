import Foundation
import PlannerCore

/// Presentation eligibility only. Commands revalidate against the locked latest
/// document, so stale chips cannot bypass the planner's identity or date rules.
public enum WeekTaskPolicy {
    public struct Summary: Equatable {
        public let tasks: [PlanTask]
        public let carried: [PlanTask]
        public let count: String
        public let more: String?
    }

    public static func summary(day: DayKey, today: DayKey, tasks: [PlanTask], expanded: Bool = false) -> Summary {
        let onDay = tasks.filter { $0.day == day }
        let done = onDay.filter(\.done)
        let past = day < today
        let rows = past ? done : onDay.filter { !$0.done } + done
        let limit = expanded ? rows.count : past ? 2 : day == today ? 5 : rows.count
        let hidden = max(0, rows.count - limit)
        let count: String
        if past {
            count = PerchL10n.format("%lld done", done.count)
        } else if day == today {
            count = PerchL10n.format("%lld of %lld done", done.count, onDay.count)
        } else {
            count = PerchL10n.format("%lld to do", onDay.count - done.count)
        }
        let carried = past ? tasks.filter { $0.carriedFrom == day && $0.day == today } : []
        return Summary(
            tasks: Array(rows.prefix(limit)), carried: carried, count: count,
            more: hidden == 0 ? nil : PerchL10n.format(past ? "and %lld more" : "%lld more", hidden))
    }

    public static func moveAction(
        id: UUID, to destination: DayRef, tasks: [PlanTask], today: DayKey
    ) -> PlannerAction? {
        moveAction(payload: id.uuidString, to: destination, tasks: tasks, today: today)
    }

    public static func scheduledCompletionAction(for task: PlanTask, today: DayKey) -> PlannerAction? {
        guard let day = task.day, day >= today else { return nil }
        return .setScheduledCompletion(task.id, expectedDay: day, completed: !task.done)
    }

    /// Compatibility policy for older direct hosts, which only check today's tasks.
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
