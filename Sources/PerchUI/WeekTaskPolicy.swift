import Foundation
import PlannerCore

/// Presentation eligibility only. Commands revalidate against the locked latest
/// document, so stale chips cannot bypass the planner's identity or date rules.
public enum WeekTaskPolicy {
    /// The currently focused control, not the last row that was activated.
    public enum KeyboardFocus: Hashable {
        case day(DayKey)
        case task(UUID)
        case other
    }

    public static func pushAction(
        focus: KeyboardFocus?, from day: DayKey, tasks: [PlanTask], today: DayKey, calendar: Calendar
    ) -> PlannerAction? {
        guard day >= today else { return nil }
        let id: UUID?
        switch focus {
        case .task(let taskID): id = taskID
        case .day(let focusedDay) where focusedDay == day:
            id = summary(day: day, today: today, tasks: tasks).tasks.first?.id
        default: return nil
        }
        guard let id, tasks.first(where: { $0.id == id })?.day == day else { return nil }
        return moveAction(id: id, to: .day(day.adding(days: 1, calendar: calendar)), tasks: tasks, today: today)
    }

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
        // Carry records remain on their source day after rollover, rescheduling,
        // completion, or another carry. The destination is not the current clock.
        let carried = past ? tasks.filter { $0.carriedFrom == day } : []
        return Summary(
            tasks: Array(rows.prefix(limit)), carried: carried, count: count,
            more: hidden == 0 ? nil : PerchL10n.format(past ? "and %lld more" : "%lld more", hidden))
    }

    public static func moveDestinations(for task: PlanTask, displayedDays: [DayKey], today: DayKey) -> [DayKey] {
        displayedDays.filter { moveAction(id: task.id, to: .day($0), tasks: [task], today: today) != nil }
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
