import Foundation

extension PlannerEngine {
    var focusActivity: [FocusSegment] {
        var segments = planner.focusLog.filter { $0.end > $0.start }
        if let running = planner.focus?.runningSegment(at: now()) { segments.append(running) }
        return segments
    }

    /// Seconds focused in each local wall-clock hour (0...23), clipped to `since`.
    /// Calendar hour intervals account for missing and repeated DST hours.
    public func activityByHour(since: Date) -> [Int: Double] {
        var hours: [Int: Double] = [:]
        for segment in focusActivity {
            var cursor = max(since, segment.start)
            while cursor < segment.end {
                guard let hour = calendar.dateInterval(of: .hour, for: cursor), hour.end > cursor else { break }
                let end = min(hour.end, segment.end)
                hours[calendar.component(.hour, from: cursor), default: 0] += end.timeIntervalSince(cursor)
                cursor = end
            }
        }
        return hours
    }
}
