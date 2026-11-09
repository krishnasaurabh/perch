import Foundation

extension PlannerEngine {
    /// Materializes only this day's scheduled occurrences. Completion-relative rules have no
    /// schedule until their predecessor finishes, so completion handles those instead.
    @discardableResult
    public mutating func applyRepeats(on day: DayKey) -> [PlanTask] {
        let series = Dictionary(grouping: planner.tasks.filter { $0.repeatRule != nil && $0.day != nil }, by: \.repeatSeriesID)
        var added: [PlanTask] = []
        // Preserve task order rather than depending on Dictionary's iteration order.
        var seen = Set<UUID>()
        for task in planner.tasks {
            let id = task.repeatSeriesID
            guard seen.insert(id).inserted, let members = series[id],
                  let anchor = members.min(by: { $0.day! < $1.day! }),
                  let start = anchor.day, let rule = anchor.repeatRule, !rule.fromCompletion,
                  day > start, rule.occurs(on: day, starting: start, calendar: calendar),
                  let template = members.filter({ $0.day! <= day }).max(by: { $0.day! < $1.day! }) else { continue }
            if let copy = materializeRepeat(template, on: day) { added.append(copy) }
        }
        return added
    }

    /// Ends the series without deleting explicitly planned occurrences or its history.
    public mutating func endRepeat(of id: UUID) throws {
        guard let task = planner.tasks.first(where: { $0.id == id }) else { throw PlannerError("Task id not found.") }
        let seriesID = task.repeatSeriesID
        for i in planner.tasks.indices where planner.tasks[i].repeatSeriesID == seriesID {
            planner.tasks[i].repeatRule = nil
        }
    }

    func nextRepeatDay(for task: PlanTask) -> DayKey? {
        guard let rule = task.repeatRule, let day = task.day else { return nil }
        guard rule.unit == .month, !rule.fromCompletion,
              let anchor = planner.tasks.filter({ $0.repeatSeriesID == task.repeatSeriesID }).compactMap(\.day).min() else {
            return rule.next(after: day, completed: today, calendar: calendar)
        }
        let start = anchor.date(calendar: calendar)
        let a = calendar.dateComponents([.year, .month], from: start)
        let b = calendar.dateComponents([.year, .month], from: day.date(calendar: calendar))
        let months = (b.year! - a.year!) * 12 + b.month! - a.month!
        let nextOffset = (months / max(1, rule.interval) + 1) * max(1, rule.interval)
        return DayKey(calendar.date(byAdding: .month, value: nextOffset, to: start)!, calendar: calendar)
    }

    mutating func materializeRepeat(_ task: PlanTask, on day: DayKey) -> PlanTask? {
        let occurrence = RepeatOccurrence(seriesID: task.repeatSeriesID, day: day)
        guard !planner.repeatOccurrences.contains(occurrence) else { return nil }
        planner.repeatOccurrences.append(occurrence)
        guard !planner.tasks.contains(where: { $0.repeatSeriesID == task.repeatSeriesID && $0.day == day }) else { return nil }
        var copy = task
        copy.id = UUID(); copy.day = day; copy.done = false; copy.completedAt = nil; copy.createdAt = now()
        copy.repeatedFrom = task.repeatSeriesID; copy.carryCount = 0
        copy.focusedSeconds = 0; copy.carriedFrom = nil; copy.reminderLink = nil
        copy.steps = task.steps.map { Subtask(title: $0.title) }
        if let reminder = task.remindAt {
            let time = calendar.dateComponents([.hour, .minute], from: reminder)
            copy.remindAt = day.reminderDate(hour: time.hour!, minute: time.minute!, resetHour: planner.preferences.resetHour, calendar: calendar)
        }
        planner.tasks.append(copy)
        return copy
    }
}

extension TaskRepeat {
    /// Tests a requested day against the original anchor, so month-end clamping does not drift.
    public func occurs(on day: DayKey, starting anchor: DayKey, calendar: Calendar = .current) -> Bool {
        guard day >= anchor, !fromCompletion else { return false }
        let start = anchor.date(calendar: calendar), target = day.date(calendar: calendar)
        let days = calendar.dateComponents([.day], from: start, to: target).day!
        if weekdaysOnly { return ![1, 7].contains(day.weekday(calendar: calendar)) }
        switch unit {
        case .day: return days % max(1, interval) == 0
        case .week:
            if weekdays.isEmpty { return days % (7 * max(1, interval)) == 0 }
            let weekStart = anchor.adding(days: -(anchor.weekday(calendar: calendar) - 1), calendar: calendar)
            let weekDays = calendar.dateComponents([.day], from: weekStart.date(calendar: calendar), to: target).day!
            return weekdays.contains(day.weekday(calendar: calendar)) && (weekDays / 7) % max(1, interval) == 0
        case .month:
            let a = calendar.dateComponents([.year, .month], from: start)
            let b = calendar.dateComponents([.year, .month], from: target)
            let months = (b.year! - a.year!) * 12 + b.month! - a.month!
            guard months % max(1, interval) == 0,
                  let occurrence = calendar.date(byAdding: .month, value: months, to: start) else { return false }
            return DayKey(occurrence, calendar: calendar) == day
        }
    }
}
