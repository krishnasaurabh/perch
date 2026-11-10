import Foundation
import PlannerCore

/// An absolute, one-shot request. Identity includes the occurrence's due instant, not its title.
public struct ScheduledReminder: Codable, Equatable, Sendable, Identifiable {
    public static let prefix = "perch.reminder."
    public let id: String
    public let date: Date
    public let title: String
    public let body: String

    public init(id: String, date: Date, title: String, body: String) {
        self.id = id; self.date = date; self.title = title; self.body = body
    }

    public init(task: PlanTask) {
        date = task.remindAt!
        id = Self.prefix + task.id.uuidString + "." + String(date.timeIntervalSinceReferenceDate)
        title = task.title
        body = "Reminder for \(task.title)."
    }
}

/// Local accounting, not proof a person saw an alert. Absence from Notification Center is ambiguous.
public struct ReminderRecord: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case scheduled, delivered, missed }
    public var date: Date
    public var state: State
    public init(date: Date, state: State) { self.date = date; self.state = state }
}

/// Bounded notification and recurrence policy, independent of views and system frameworks.
public enum ReminderSchedule {
    public static let horizonDays = 14
    // Leave headroom for one-off timer notifications in the OS queue.
    public static let capacity = 60
    public static let retention: TimeInterval = 30 * 24 * 60 * 60
    public static let deliveryGrace: TimeInterval = 60

    public struct Plan {
        public var requests: [ScheduledReminder]
        public var remove: [String]
        public var records: [String: ReminderRecord]
    }

    public static func days(today: DayKey, calendar: Calendar) -> [DayKey] {
        (0..<horizonDays).map { today.adding(days: $0, calendar: calendar) }
    }

    public static func reconcile(
        planner: Planner, now: Date, calendar: Calendar = .current,
        pending: [ScheduledReminder], delivered: Set<String>, records: [String: ReminderRecord], authorized: Bool
    ) -> Plan {
        let engine = PlannerEngine(planner: planner, now: { now }, calendar: calendar)
        let end = engine.today.adding(days: horizonDays, calendar: calendar)
            .start(resetHour: planner.preferences.resetHour, calendar: calendar)
        let eligible = planner.tasks.filter { !$0.done && $0.day != nil && $0.remindAt != nil }
        let candidates: [ScheduledReminder] = eligible.map { ScheduledReminder(task: $0) }.sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
        }
        var history = records.filter { $0.value.date >= now.addingTimeInterval(-retention) }
        let active = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let queued = Dictionary(pending.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Observe delivery before considering cancellation, including a task completed after its alert.
        for id in delivered {
            if let date = active[id]?.date ?? history[id]?.date ?? queued[id]?.date {
                history[id] = ReminderRecord(date: date, state: .delivered)
            }
        }
        var wanted: [ScheduledReminder] = []
        for request in candidates {
            if let state = history[request.id]?.state, state == .delivered || state == .missed { continue }
            if request.date <= now {
                // Give an already accepted request time to leave the OS pending queue. Never replay it.
                if authorized, queued[request.id] != nil,
                    now.timeIntervalSince(request.date) < deliveryGrace
                {
                    wanted.append(request)
                } else {
                    history[request.id] = ReminderRecord(date: request.date, state: .missed)
                }
            } else if authorized && request.date < end {
                wanted.append(request)
            }
        }
        wanted = Array(wanted.prefix(capacity))
        let keep = Set(wanted.map(\.id))
        let obsoleteDelivered = delivered.filter { $0.hasPrefix(ScheduledReminder.prefix) && active[$0] == nil }
        let obsoletePending = queued.keys.filter { $0.hasPrefix(ScheduledReminder.prefix) && !keep.contains($0) }
        let remove = Set(obsoletePending).union(obsoleteDelivered).sorted()
        return Plan(requests: wanted, remove: remove, records: history)
    }
}
