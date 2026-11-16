import Foundation
import PlannerCore

/// Finished tasks, independent of their current scheduled day or any native UI framework.
public struct HistoryModel: Sendable {
    public enum Filter: String, CaseIterable, Sendable { case everything, carried, time, agent }
    public struct Group: Sendable {
        public let day: DayKey
        public let tasks: [PlanTask]
        public let initiallyExpanded: Bool
    }
    public let groups: [Group]
    public let undated: [PlanTask]
    public let weekDone: Int
    public let weekActiveDays: Int

    /// The limit is planned time, not evidence that a block was actually spent.
    public static func recordedBlockMinutes(_ task: PlanTask) -> Int? {
        guard task.focusedSeconds.isFinite, task.focusedSeconds > 0 else { return nil }
        return Int(task.focusedSeconds / 60)
    }

    public init(engine: PlannerEngine, query: String = "", filter: Filter = .everything, locale: Locale = .current) {
        let week = YourWeekModel(engine: engine)
        weekDone = week.done
        weekActiveDays = week.activeDays
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let tasks = engine.planner.tasks.filter { task in
            guard task.done else { return false }
            if !query.isEmpty
                && task.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
                    == nil
            {
                return false
            }
            switch filter {
            case .everything: return true
            case .carried: return task.carryCount > 0
            case .time: return task.focusedSeconds > 0 || task.startAt != nil
            case .agent: return task.agentID != nil
            }
        }
        var byDay: [DayKey: [PlanTask]] = [:]
        var withoutDay: [PlanTask] = []
        for task in tasks {
            if let day = YourWeekModel.completionDay(task, engine: engine) {
                byDay[day, default: []].append(task)
            } else {
                withoutDay.append(task)
            }
        }
        groups = byDay.keys.sorted(by: >).enumerated().map { index, day in
            Group(day: day, tasks: byDay[day]!, initiallyExpanded: index < 2 || !query.isEmpty || filter != .everything)
        }
        undated = withoutDay
    }
}
