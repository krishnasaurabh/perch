import EventKit
import Foundation
import PlannerCore

struct ReminderSyncResult {
    var links: [UUID: String] = [:]
    var completed: [UUID] = []
}

@MainActor
protocol RemindersAccess {
    var hasAccess: Bool { get }
    func requestAccess() async throws
    func synchronize(_ planner: Planner, today: DayKey) throws -> ReminderSyncResult
}

@MainActor
final class SystemRemindersAccess: RemindersAccess {
    private let ek = EKEventStore()
    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    func requestAccess() async throws { _ = try await ek.requestFullAccessToReminders() }
    private func list() throws -> EKCalendar {
        if let c = ek.calendars(for: .reminder).first(where: { $0.title == RemindersSync.listName }) { return c }
        let c = EKCalendar(for: .reminder, eventStore: ek)
        c.title = RemindersSync.listName
        guard
            let source = ek.defaultCalendarForNewReminders()?.source
                ?? ek.sources.first(where: { $0.sourceType == .calDAV || $0.sourceType == .local })
        else { throw PlannerError("Perch found no Reminders account on this Mac.") }
        c.source = source
        try ek.saveCalendar(c, commit: true)
        return c
    }

    func synchronize(_ planner: Planner, today: DayKey) throws -> ReminderSyncResult {
        let cal = try list()
        let pred = ek.predicateForReminders(in: [cal])
        var fetched: [EKReminder] = []
        let sem = DispatchSemaphore(value: 0)
        ek.fetchReminders(matching: pred) { r in
            fetched = r ?? []; sem.signal()
        }
        sem.wait()
        let byID = Dictionary(fetched.map { ($0.calendarItemIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        var links: [UUID: String] = [:]
        var completedRemotely: [UUID] = []

        for t in planner.tasks {
            guard let d = t.day, d >= today else { continue }
            let r = t.reminderLink.flatMap { byID[$0] }
            if let r, r.isCompleted, !t.done, d == today { completedRemotely.append(t.id); continue }
            if t.done {
                if let r, !r.isCompleted { r.isCompleted = true; try? ek.save(r, commit: false) }; continue
            }
            let rem = r ?? EKReminder(eventStore: ek)
            rem.calendar = cal
            rem.title = t.title
            rem.notes = t.notes.isEmpty ? nil : t.notes
            rem.priority = [.high: 1, .medium: 5, .low: 9, .none: 0][t.priority]!
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: d.date())
            if let at = t.remindAt {
                comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
                rem.alarms = planner.preferences.ringOnPhone ? [EKAlarm(absoluteDate: at)] : nil
            } else {
                rem.alarms = nil
            }
            rem.dueDateComponents = comps
            try ek.save(rem, commit: false)
            if t.reminderLink != rem.calendarItemIdentifier { links[t.id] = rem.calendarItemIdentifier }
        }
        try ek.commit()
        return ReminderSyncResult(links: links, completed: completedRemotely)
    }
}
