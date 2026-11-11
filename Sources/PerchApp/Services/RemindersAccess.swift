import EventKit
import Foundation
import PerchReminders

@MainActor
protocol RemindersAccess: ReminderRepository {
    func requestAccess() async throws
}

/// EventKit transport only. Reconciliation and persisted ownership are platform independent.
@MainActor
final class SystemRemindersAccess: RemindersAccess {
    private let ek: EKEventStore
    init(eventStore: EKEventStore = EKEventStore()) { ek = eventStore }
    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    func requestAccess() async throws {
        do {
            let granted = try await ek.requestFullAccessToReminders()
            PlatformLog.reminders.info("requestAccess completed granted=\(granted, privacy: .public)")
        } catch {
            PlatformLog.reminders.error("requestAccess failed code=\(PlatformLog.errorCode(error), privacy: .public)")
            throw error
        }
    }

    func createCalendar() throws -> String {
        try requireAccess()
        // A title is not proof of ownership. Never adopt a user's existing list, even with the same name.
        let calendar = EKCalendar(for: .reminder, eventStore: ek)
        calendar.title = "Perch"
        guard
            let source = ek.defaultCalendarForNewReminders()?.source
                ?? ek.sources.first(where: { $0.sourceType == .calDAV || $0.sourceType == .local })
        else {
            throw ReminderSyncError.stopped("No Reminders account is available on this Mac.")
        }
        calendar.source = source
        try ek.saveCalendar(calendar, commit: true)
        PlatformLog.reminders.info("calendar created id=\(calendar.calendarIdentifier, privacy: .private)")
        return calendar.calendarIdentifier
    }

    func fetch(calendarID: String) async throws -> [ReminderSyncRecord] {
        try requireAccess()
        guard let calendar = ek.calendar(withIdentifier: calendarID) else {
            throw ReminderSyncError.stopped(
                "The Perch Reminders list was removed or moved. Sync is stopped; no replacement list was created.")
        }
        let predicate = ek.predicateForReminders(in: [calendar])
        let reminders: [ReminderSyncRecord] = try await withCheckedThrowingContinuation { continuation in
            ek.fetchReminders(matching: predicate) { reminders in
                if let reminders {
                    continuation.resume(returning: reminders.map(Self.snapshot))
                } else {
                    continuation.resume(
                        throwing: ReminderSyncError.stopped(
                            "Reminders could not be read. Retry after checking permission."))
                }
            }
        }
        try requireAccess()
        PlatformLog.reminders.debug("fetch completed count=\(reminders.count, privacy: .public)")
        return reminders
    }

    func save(fields: ReminderFields, owner: ReminderOwner, calendarID: String, replacing expected: ReminderSyncRecord?)
        throws -> ReminderSyncRecord
    {
        try requireAccess()
        let reminder: EKReminder
        if let expected {
            reminder = try current(expected)
            guard expected.owner == owner else { throw conflict() }
            if expected.fields == fields { return expected }
        } else {
            guard let calendar = ek.calendar(withIdentifier: calendarID) else { throw conflict() }
            reminder = EKReminder(eventStore: ek)
            reminder.calendar = calendar
            reminder.url = owner.url
        }
        reminder.title = fields.title
        reminder.notes = fields.notes
        reminder.priority = fields.priority
        reminder.dueDateComponents = fields.due
        reminder.alarms = fields.alarm.map { [EKAlarm(absoluteDate: $0)] }
        reminder.isCompleted = fields.completed
        // Commit individually. Errors surface; a later retry fetches committed records by their ownership marker.
        do { try ek.save(reminder, commit: true) } catch {
            PlatformLog.reminders.error("save failed code=\(PlatformLog.errorCode(error), privacy: .public)")
            ek.reset(); throw error
        }
        PlatformLog.reminders.debug("save completed replacing=\(expected != nil, privacy: .public)")
        return Self.snapshot(reminder)
    }

    func remove(_ expected: ReminderSyncRecord) throws {
        try requireAccess()
        let reminder = try current(expected)
        guard expected.owner != nil else { throw conflict() }
        do { try ek.remove(reminder, commit: true) } catch {
            PlatformLog.reminders.error("remove failed code=\(PlatformLog.errorCode(error), privacy: .public)")
            ek.reset(); throw error
        }
        PlatformLog.reminders.debug("remove completed id=\(expected.id, privacy: .private)")
    }

    private func current(_ expected: ReminderSyncRecord) throws -> EKReminder {
        guard let reminder = ek.calendarItem(withIdentifier: expected.id) as? EKReminder,
            Self.snapshot(reminder) == expected
        else { throw conflict() }
        return reminder
    }

    private func requireAccess() throws {
        guard hasAccess else {
            PlatformLog.reminders.error("operation rejected authorization=revoked")
            throw ReminderSyncError.stopped(
                "Reminders permission was revoked. Grant access in System Settings and retry.")
        }
    }
    private func conflict() -> ReminderSyncError {
        PlatformLog.reminders.error("operation rejected reason=conflict")
        return .stopped(
            "A reminder changed during sync. Nothing else was overwritten; retry to review the latest version.")
    }
    private nonisolated static func snapshot(_ reminder: EKReminder) -> ReminderSyncRecord {
        let alarms = reminder.alarms ?? []
        let unsupported =
            !(reminder.recurrenceRules ?? []).isEmpty || alarms.count > 1
            || alarms.contains { $0.absoluteDate == nil || $0.structuredLocation != nil }
            || !(reminder.location ?? "").isEmpty || reminder.startDateComponents != nil
            || (reminder.dueDateComponents?.second ?? 0) != 0
        return ReminderSyncRecord(
            id: reminder.calendarItemIdentifier, calendarID: reminder.calendar.calendarIdentifier,
            owner: ReminderOwner(url: reminder.url),
            fields: ReminderFields(
                title: reminder.title ?? "", notes: reminder.notes?.isEmpty == true ? nil : reminder.notes,
                priority: reminder.priority, due: reminder.dueDateComponents, alarm: alarms.first?.absoluteDate,
                completed: reminder.isCompleted),
            revision: reminder.lastModifiedDate.map { String($0.timeIntervalSinceReferenceDate) } ?? "",
            unsupported: unsupported)
    }
}
