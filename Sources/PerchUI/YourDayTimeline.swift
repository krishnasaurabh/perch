import Foundation
import PlannerCore

/// A value-only schedule for a logical planner day. Intervals are half-open: touching
/// blocks do not overlap. Gaps use the union of occupied intervals, not row order.
public struct YourDayTimeline: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case task, meeting, gap, preview }

    public struct Meeting: Equatable, Sendable {
        public let id: String
        public let title: String
        public let start: Date
        public let end: Date
        public let allDay: Bool
        public let done: Bool

        public init(id: String, title: String, start: Date, end: Date, allDay: Bool = false, done: Bool = false) {
            self.id = id; self.title = title; self.start = start; self.end = end
            self.allDay = allDay; self.done = done
        }
    }

    public struct Preview: Equatable, Sendable {
        public let start: Date
        public let minutes: Int
        public init(start: Date, minutes: Int) { self.start = start; self.minutes = minutes }
    }

    public struct Item: Equatable, Identifiable, Sendable {
        public let id: String
        public let kind: Kind
        public let taskID: UUID?
        public let title: String
        public let start: Date
        public let end: Date
        public var done = false
        public var carried = false
        public var running = false
        public var overlaps = false
        public var minutes: Int { max(0, Int((end.timeIntervalSince(start) / 60).rounded())) }
    }

    public let start: Date
    public let end: Date
    public let items: [Item]
    public let blockCount: Int
    public let meetingCount: Int
    public static let snapMinutes = 15

    public init(
        tasks: [PlanTask], meetings: [Meeting], day: DayKey, now: Date,
        calendar: Calendar, resetHour: Int, defaultMinutes: Int,
        focus: FocusSession? = nil, preview: Preview? = nil
    ) {
        start = day.start(resetHour: resetHour, calendar: calendar)
        end = day.adding(days: 1, calendar: calendar).start(resetHour: resetHour, calendar: calendar)
        let bounds = start..<end
        var rows: [Item] = tasks.compactMap { task in
            guard task.day == day, let planned = task.startAt, bounds.contains(planned) else { return nil }
            let running = !task.done && focus?.taskID == task.id && focus?.state == .running
            let rowStart = running ? (focus?.startedAt ?? planned) : planned
            let duration = Double(max(1, task.minutes ?? defaultMinutes)) * 60
            let rowEnd: Date
            if running, let remaining = focus?.remaining(at: now) {
                rowEnd = now.addingTimeInterval(remaining)
            } else {
                rowEnd = rowStart.addingTimeInterval(duration)
            }
            return Item(
                id: "task:\(task.id)", kind: .task, taskID: task.id, title: task.title,
                start: rowStart, end: max(rowStart, rowEnd), done: task.done,
                carried: task.carriedFrom != nil || task.carryCount > 0, running: running)
        }
        blockCount = rows.filter { !$0.done }.count
        let dayEnd = end
        let validMeetings = meetings.filter {
            !$0.allDay && $0.end > $0.start && bounds.contains($0.start) && $0.end <= dayEnd
                && calendar.isDate($0.start, inSameDayAs: $0.end.addingTimeInterval(-1))
        }
        meetingCount = validMeetings.count
        rows += validMeetings.map {
            Item(
                id: "meeting:\($0.id)", kind: .meeting, taskID: nil, title: $0.title,
                start: $0.start, end: $0.end, done: $0.done)
        }
        if let preview, bounds.contains(preview.start), preview.minutes > 0 {
            rows.append(
                Item(
                    id: "preview", kind: .preview, taskID: nil, title: "",
                    start: preview.start, end: preview.start.addingTimeInterval(Double(preview.minutes) * 60)))
        }
        rows.sort(by: Self.ordered)
        // Every real intersection is marked, including non-adjacent nested intervals.
        for index in rows.indices {
            rows[index].overlaps = rows.indices.contains { other in
                index != other && rows[index].start < rows[other].end && rows[other].start < rows[index].end
            }
        }
        var cursor = max(start, now)
        var gaps: [Item] = []
        for row in rows {
            let next = min(end, row.start)
            if next.timeIntervalSince(cursor) >= Double(Self.snapMinutes * 60) {
                gaps.append(Self.gap(from: cursor, to: next))
            }
            cursor = max(cursor, min(end, row.end))
        }
        if end.timeIntervalSince(cursor) >= Double(Self.snapMinutes * 60) {
            gaps.append(Self.gap(from: cursor, to: end))
        }
        items = (rows + gaps).sorted(by: Self.ordered)
    }

    /// Snap in local wall time, then constrain to the logical day. Calendar arithmetic
    /// retains the chosen occurrence in repeated hours and skips nonexistent DST times.
    public func snapped(_ date: Date, calendar: Calendar) -> Date {
        let minuteStart = calendar.dateInterval(of: .minute, for: date)?.start ?? date
        let minute = calendar.component(.minute, from: minuteStart)
        let remainder = minute % Self.snapMinutes
        let delta = remainder < Self.snapMinutes / 2 + 1 ? -remainder : Self.snapMinutes - remainder
        let result = calendar.date(byAdding: .minute, value: delta, to: minuteStart) ?? minuteStart
        return min(max(start, result), end.addingTimeInterval(-Double(Self.snapMinutes * 60)))
    }

    /// A gap uses its whole interval; a block offers its start/end as insertion slots.
    public func dropTime(in item: Item, fraction: Double, calendar: Calendar) -> Date {
        let fraction = min(1, max(0, fraction.isFinite ? fraction : 0))
        let value: Date
        if item.kind == .gap {
            value = item.start.addingTimeInterval(item.end.timeIntervalSince(item.start) * fraction)
        } else {
            value = fraction < 0.5 ? item.start : item.end
        }
        return snapped(value, calendar: calendar)
    }

    private static func gap(from start: Date, to end: Date) -> Item {
        Item(
            id: "gap:\(start.timeIntervalSinceReferenceDate)", kind: .gap, taskID: nil, title: "", start: start,
            end: end)
    }

    private static func ordered(_ lhs: Item, _ rhs: Item) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        let rank: (Kind) -> Int = { kind in
            switch kind {
            case .task: return 0;
            case .meeting: return 1;
            case .preview: return 2;
            case .gap: return 3
            }
        }
        if rank(lhs.kind) != rank(rhs.kind) { return rank(lhs.kind) < rank(rhs.kind) }
        return lhs.id < rhs.id
    }
}
