import Foundation

extension PlannerEngine {
    /// Materializes only this day's scheduled occurrences. Completion-relative rules have no
    /// schedule until their predecessor finishes, so completion handles those instead.
    @discardableResult
    public mutating func applyRepeats(on day: DayKey) -> [PlanTask] {
        let series = Dictionary(
            grouping: planner.tasks.filter { $0.repeatRule != nil && $0.day != nil }, by: \.repeatSeriesID)
        var added: [PlanTask] = []
        // Preserve task order rather than depending on Dictionary's iteration order.
        var seen = Set<UUID>()
        for task in planner.tasks {
            let id = task.repeatSeriesID
            guard seen.insert(id).inserted, let members = series[id],
                let template = members.filter({ $0.day! <= day }).max(by: { $0.day! < $1.day! }),
                let rule = template.repeatRule, !rule.fromCompletion
            else { continue }
            // Old v1 exports have unlinked completed predecessors beside live successors.
            // Retain that history, but do not turn each completed singleton into a new series.
            if isLegacyRetiredSingleton(template) { continue }
            guard let start = repeatAnchor(for: template), day > start,
                rule.occurs(on: day, starting: start, calendar: calendar)
            else { continue }
            preserveRepeatAnchor(of: template.id)
            if let copy = materializeRepeat(template, on: day) { added.append(copy) }
        }
        return added
    }

    /// Ends the series without deleting explicitly planned occurrences or its history.
    public mutating func endRepeat(of id: UUID) throws {
        guard let task = planner.tasks.first(where: { $0.id == id }) else { throw PlannerError("Task id not found.") }
        try requireEditable(task)
        guard task.repeatRule != nil else { return }
        let seriesID = task.repeatSeriesID
        for i in planner.tasks.indices where planner.tasks[i].repeatSeriesID == seriesID {
            planner.tasks[i].repeatRule = nil
        }
    }

    private func repeatAnchor(for task: PlanTask) -> DayKey? {
        let members = planner.tasks.filter { $0.repeatSeriesID == task.repeatSeriesID && $0.repeatRule != nil }
        return members.compactMap(\.repeatAnchor).min()
            ?? members.flatMap { [$0.day, $0.carriedFrom].compactMap { $0 } }.min()
            ?? task.repeatAnchor ?? task.day
    }

    private func isLegacyRetiredSingleton(_ task: PlanTask) -> Bool {
        task.done && task.repeatedFrom == nil && task.repeatAnchor == nil
            && !planner.tasks.contains {
                $0.id != task.id && $0.repeatSeriesID == task.repeatSeriesID && $0.repeatRule != nil
            }
    }

    mutating func preserveRepeatAnchor(of id: UUID) {
        guard let task = planner.tasks.first(where: { $0.id == id }), task.repeatRule != nil,
            !isLegacyRetiredSingleton(task),
            let anchor = repeatAnchor(for: task)
        else { return }
        for i in planner.tasks.indices
        where planner.tasks[i].repeatSeriesID == task.repeatSeriesID && planner.tasks[i].repeatRule != nil {
            planner.tasks[i].repeatAnchor = anchor
        }
    }

    func nextRepeatDay(for task: PlanTask) -> DayKey? {
        guard let rule = task.repeatRule, let day = task.day else { return nil }
        if rule.fromCompletion { return rule.next(after: day, completed: today, calendar: calendar) }
        guard let anchor = repeatAnchor(for: task) else { return nil }
        return rule.nextScheduled(after: day, starting: anchor, calendar: calendar)
    }

    mutating func materializeRepeat(_ task: PlanTask, on day: DayKey) -> PlanTask? {
        let occurrence = RepeatOccurrence(seriesID: task.repeatSeriesID, day: day)
        guard !planner.repeatOccurrences.contains(occurrence) else { return nil }
        planner.repeatOccurrences.append(occurrence)
        guard !planner.tasks.contains(where: { $0.repeatSeriesID == task.repeatSeriesID && $0.day == day }) else {
            return nil
        }
        var copy = task
        copy.id = UUID(); copy.day = day; copy.done = false; copy.completedAt = nil; copy.createdAt = now()
        copy.repeatedFrom = task.repeatSeriesID; copy.carryCount = 0
        copy.repeatAnchor = repeatAnchor(for: task)
        copy.focusedSeconds = 0; copy.carriedFrom = nil; copy.reminderLink = nil
        copy.steps = task.steps.map { Subtask(title: $0.title) }
        if let reminder = task.remindAt {
            let time = calendar.dateComponents([.hour, .minute], from: reminder)
            copy.remindAt = day.reminderDate(
                hour: time.hour!, minute: time.minute!, resetHour: planner.preferences.resetHour, calendar: calendar)
        }
        planner.tasks.append(copy)
        return copy
    }
}

extension TaskRepeat {
    /// Next member of the original schedule strictly after this occurrence's current day.
    /// Kept separate from `next(after:completed:)`, whose public contract is occurrence-relative.
    func nextScheduled(after day: DayKey, starting anchor: DayKey, calendar: Calendar) -> DayKey {
        let interval = max(1, interval)
        let base = max(day, anchor)
        if weekdaysOnly {
            var next = base.adding(days: 1, calendar: calendar)
            while [1, 7].contains(next.weekday(calendar: calendar)) { next = next.adding(days: 1, calendar: calendar) }
            return next
        }
        switch unit {
        case .day:
            let stride = interval
            let elapsed = calendar.dateComponents(
                [.day], from: anchor.date(calendar: calendar), to: base.date(calendar: calendar)
            ).day!
            return anchor.adding(days: (elapsed / stride + 1) * stride, calendar: calendar)
        case .week:
            if weekdays.isEmpty {
                let elapsed = calendar.dateComponents(
                    [.day], from: anchor.date(calendar: calendar), to: base.date(calendar: calendar)
                ).day!
                let stride = interval * 7
                return anchor.adding(days: (elapsed / stride + 1) * stride, calendar: calendar)
            }
            let sunday = anchor.adding(days: -(anchor.weekday(calendar: calendar) - 1), calendar: calendar)
            let elapsed = calendar.dateComponents(
                [.day], from: sunday.date(calendar: calendar), to: base.date(calendar: calendar)
            ).day!
            let cycle = elapsed / (interval * 7)
            for offset in [cycle, cycle + 1] {
                for weekday in weekdays.sorted() {
                    let next = sunday.adding(days: offset * interval * 7 + weekday - 1, calendar: calendar)
                    if next > day && next >= anchor { return next }
                }
            }
            return anchor.adding(days: interval * 7, calendar: calendar)
        case .month:
            let a = calendar.dateComponents([.year, .month], from: anchor.date(calendar: calendar))
            let b = calendar.dateComponents([.year, .month], from: base.date(calendar: calendar))
            let elapsed = (b.year! - a.year!) * 12 + b.month! - a.month!
            var offset = (elapsed / interval) * interval
            var next = DayKey(
                calendar.date(byAdding: .month, value: offset, to: anchor.date(calendar: calendar))!, calendar: calendar
            )
            if next <= day {
                offset += interval;
                next = DayKey(
                    calendar.date(byAdding: .month, value: offset, to: anchor.date(calendar: calendar))!,
                    calendar: calendar)
            }
            return next
        }
    }

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
                let occurrence = calendar.date(byAdding: .month, value: months, to: start)
            else { return false }
            return DayKey(occurrence, calendar: calendar) == day
        }
    }
}
