import Foundation

public struct NotchActivity: Equatable, Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case reminder, eventSoon, eventNow, screenshot

        var priority: Int {
            switch self {
            case .eventNow: return 3
            case .reminder: return 2
            case .screenshot: return 1
            case .eventSoon: return 0
            }
        }
    }

    public var kind: Kind
    public var title: String
    /// The beginning of the visibility window, not the calendar event's start for eventSoon.
    public var date: Date
    public var id: String
    public var taskID: UUID?
    public var fileURL: URL?

    public init(kind: Kind, title: String, date: Date, id: String, taskID: UUID? = nil, fileURL: URL? = nil) {
        self.kind = kind; self.title = title; self.date = date; self.id = id
        self.taskID = taskID; self.fileURL = fileURL
    }

    public var duration: TimeInterval {
        switch kind {
        case .reminder: return NotchActivityTimeline.reminderDuration
        case .eventSoon: return NotchActivityTimeline.eventLead
        case .eventNow: return NotchActivityTimeline.lateGrace
        case .screenshot: return NotchActivityTimeline.screenshotDuration
        }
    }
    public var end: Date { date.addingTimeInterval(duration) }
}

/// Pure presentation policy. No timers, file IO, calendar framework objects, or mutations.
public struct NotchActivityTimeline: Equatable, Sendable {
    public static let eventLead: TimeInterval = 5 * 60
    public static let lateGrace: TimeInterval = 60
    public static let reminderDuration: TimeInterval = 60
    public static let screenshotDuration: TimeInterval = 8

    public struct Event: Equatable, Sendable {
        public var id: String
        public var title: String
        public var start: Date
        public var isAllDay: Bool
        public init(id: String, title: String, start: Date, isAllDay: Bool = false) {
            self.id = id; self.title = title; self.start = start; self.isAllDay = isAllDay
        }
    }

    public struct Screenshot: Equatable, Sendable {
        public var id: String
        public var title: String
        public var date: Date
        public var fileURL: URL
        public init(id: String, title: String, date: Date, fileURL: URL) {
            self.id = id; self.title = title; self.date = date; self.fileURL = fileURL
        }
    }

    public let activities: [NotchActivity]

    public init(activities: [NotchActivity]) {
        self.activities = activities.sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
        }
    }

    public init(planner: Planner, events: [Event] = [], screenshots: [Screenshot] = []) {
        self.init(activities: Self.triggers(planner: planner, events: events, screenshots: screenshots))
    }

    public static func triggers(planner: Planner, events: [Event] = [], screenshots: [Screenshot] = [])
        -> [NotchActivity]
    {
        var activities = planner.tasks.compactMap { task -> NotchActivity? in
            guard !task.done, task.day != nil, let date = task.remindAt else { return nil }
            return NotchActivity(
                kind: .reminder, title: task.title, date: date,
                id: identity(.reminder, source: task.id.uuidString, date: date), taskID: task.id)
        }
        for event in events where !event.isAllDay {
            activities.append(
                NotchActivity(
                    kind: .eventSoon, title: event.title, date: event.start.addingTimeInterval(-eventLead),
                    id: identity(.eventSoon, source: event.id, date: event.start)))
            activities.append(
                NotchActivity(
                    kind: .eventNow, title: event.title, date: event.start,
                    id: identity(.eventNow, source: event.id, date: event.start)))
        }
        activities += screenshots.map { shot in
            NotchActivity(
                kind: .screenshot, title: shot.title, date: shot.date,
                id: identity(.screenshot, source: shot.id, date: shot.date), fileURL: shot.fileURL)
        }
        return activities.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }

    /// Half-open windows prevent expired triggers from being replayed on refresh.
    /// Priority is eventNow, reminder, screenshot, eventSoon; ties prefer newest, then lexical ID.
    public func showing(at date: Date, dismissed: Set<String> = []) -> NotchActivity? {
        activities.filter { $0.date <= date && date < $0.end && !dismissed.contains($0.id) }.sorted {
            if $0.kind.priority != $1.kind.priority { return $0.kind.priority > $1.kind.priority }
            return $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
        }.first
    }

    /// The first strictly future boundary that changes visible activity, ignoring hidden boundaries.
    public func nextChange(after date: Date, dismissed: Set<String> = []) -> Date? {
        let current = showing(at: date, dismissed: dismissed)
        let boundaries = Set(activities.filter { !dismissed.contains($0.id) }.flatMap { [$0.date, $0.end] })
        return boundaries.filter { $0 > date }.sorted().first {
            showing(at: $0, dismissed: dismissed) != current
        }
    }

    private static func identity(_ kind: NotchActivity.Kind, source: String, date: Date) -> String {
        "\(kind.rawValue):\(source):\(date.timeIntervalSinceReferenceDate)"
    }
}
