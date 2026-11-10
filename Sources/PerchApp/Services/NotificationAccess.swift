import Foundation
import PerchUI
import UserNotifications

@MainActor
protocol NotificationAccess {
    func setDelegate(_ delegate: any UNUserNotificationCenterDelegate)
    func isAuthorized() async -> Bool
    func requestAuthorization() async throws
    func post(id: String, title: String, body: String)
    func pendingReminders() async -> [ScheduledReminder]
    func deliveredReminderIDs() async -> Set<String>
    func schedule(_ reminder: ScheduledReminder) async throws
    func removeReminders(ids: [String])
}

@MainActor
final class SystemNotificationAccess: NotificationAccess {
    func setDelegate(_ delegate: any UNUserNotificationCenterDelegate) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = delegate
    }
    func isAuthorized() async -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        PlatformLog.notifications.debug("authorization status=\(status.rawValue, privacy: .public)")
        return status == .authorized
    }
    func requestAuthorization() async throws {
        guard Bundle.main.bundleIdentifier != nil else { return }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            PlatformLog.notifications.info("requestAuthorization completed granted=\(granted, privacy: .public)")
        } catch {
            PlatformLog.notifications.error(
                "requestAuthorization failed code=\(PlatformLog.errorCode(error), privacy: .public)")
            throw error
        }
    }
    func pendingReminders() async -> [ScheduledReminder] {
        guard Bundle.main.bundleIdentifier != nil else { return [] }
        let reminders: [ScheduledReminder] = await UNUserNotificationCenter.current().pendingNotificationRequests()
            .compactMap { request in
                guard request.identifier.hasPrefix(ScheduledReminder.prefix),
                    let stamp = request.content.userInfo["due"] as? Double
                else { return nil }
                return ScheduledReminder(
                    id: request.identifier, date: Date(timeIntervalSinceReferenceDate: stamp),
                    title: request.content.title, body: request.content.body)
            }
        PlatformLog.notifications.debug("pending loaded count=\(reminders.count, privacy: .public)")
        return reminders
    }
    func deliveredReminderIDs() async -> Set<String> {
        guard Bundle.main.bundleIdentifier != nil else { return [] }
        let ids = Set(await UNUserNotificationCenter.current().deliveredNotifications().map { $0.request.identifier })
        PlatformLog.notifications.debug("delivered loaded count=\(ids.count, privacy: .public)")
        return ids
    }
    func schedule(_ reminder: ScheduledReminder) async throws {
        guard Bundle.main.bundleIdentifier != nil else { return }
        do {
            try await UNUserNotificationCenter.current().add(Self.request(for: reminder))
            PlatformLog.notifications.debug("scheduled id=\(reminder.id, privacy: .private)")
        } catch {
            PlatformLog.notifications.error("schedule failed code=\(PlatformLog.errorCode(error), privacy: .public)")
            throw error
        }
    }
    static func request(for reminder: ScheduledReminder) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = reminder.title; content.body = reminder.body; content.sound = .default
        content.userInfo = ["due": reminder.date.timeIntervalSinceReferenceDate]
        // The planner resolved local wall time (including DST) already. Pin that absolute instant,
        // so a timezone change does not silently retime an existing task.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let triggerDate = Date(timeIntervalSince1970: reminder.date.timeIntervalSince1970.rounded(.up))
        var parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: triggerDate)
        parts.calendar = utc; parts.timeZone = utc.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        return UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)
    }
    func removeReminders(ids: [String]) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        PlatformLog.notifications.debug("removed count=\(ids.count, privacy: .public)")
    }
    func post(id: String, title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) {
            error in
            if let error {
                PlatformLog.notifications.error("post failed code=\(PlatformLog.errorCode(error), privacy: .public)")
            } else {
                PlatformLog.notifications.debug("post completed id=\(id, privacy: .private)")
            }
        }
    }
}
