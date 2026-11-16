import Foundation
import PlannerCore

/// Calendar-week review. All dates use the planner's logical day and regional week start.
public struct YourWeekModel: Sendable {
    public struct Day: Equatable, Sendable {
        public let day: DayKey
        public let done: Int
        public let isToday: Bool
        public let isFuture: Bool
    }

    public let weekStart: DayKey
    public let weekEnd: DayKey
    public let nextWeekStart: DayKey
    public let days: [Day]
    public let done: Int
    public let previousDone: Int
    public let activeDays: Int
    public let keptGoing: Int
    public let focusSeconds: Double
    public let stillWaiting: [PlanTask]

    public var blockHours: Int { Int(focusSeconds / 3600) }
    public var blockMinutes: Int { Int(focusSeconds / 60) % 60 }

    public init(engine: PlannerEngine) {
        let calendar = engine.calendar
        let today = engine.today
        let offset = (today.weekday(calendar: calendar) - calendar.firstWeekday + 7) % 7
        let start = today.adding(days: -offset, calendar: calendar)
        weekStart = start
        weekEnd = start.adding(days: 6, calendar: calendar)
        nextWeekStart = start.adding(days: 7, calendar: calendar)
        let tasks = engine.planner.tasks
        let completions = Dictionary(
            grouping: tasks.filter(\.done).compactMap { Self.completionDay($0, engine: engine) }, by: { $0 }
        )
        .mapValues(\.count)
        days = (0..<7).map { index in
            let day = start.adding(days: index, calendar: calendar)
            return Day(
                day: day, done: day > today ? 0 : completions[day, default: 0], isToday: day == today,
                isFuture: day > today)
        }
        done = days.reduce(0) { $0 + $1.done }
        activeDays = days.filter { $0.done > 0 }.count
        let previousStart = start.adding(days: -7, calendar: calendar)
        previousDone = completions.filter { $0.key >= previousStart && $0.key < start }.values.reduce(0, +)

        // Walk only recorded days. An unplanned day (weekday or weekend) is a day off,
        // not a reset; a planned day without anything finished is a real break.
        let plannedDays = Set(tasks.compactMap(\.day).filter { $0 <= today })
        let recordedDays = plannedDays.union(completions.keys.filter { $0 <= today }).sorted(by: >)
        var kept = 0
        for day in recordedDays {
            if completions[day, default: 0] > 0 { kept += 1 } else { break }
        }
        keptGoing = kept
        // Core accounts for recorded, paused and currently running block intervals,
        // including DST and the day boundary. A calendar week so far is a subset of this range.
        focusSeconds = engine.insights().lastSeven.filter { $0.day >= start }.reduce(0) { $0 + $1.focusSeconds }
        stillWaiting = tasks.filter { !$0.done && $0.carryCount >= 2 && ($0.day == nil || $0.day! >= today) }
    }

    /// Old documents may not have a completion timestamp. Keep their scheduled day usable.
    public static func completionDay(_ task: PlanTask, engine: PlannerEngine) -> DayKey? {
        task.completedAt.map { engine.dayKey($0) } ?? task.day
    }
}
