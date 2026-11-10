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
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized
    }
    func requestAuthorization() async throws {
        guard Bundle.main.bundleIdentifier != nil else { return }
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    func pendingReminders() async -> [ScheduledReminder] {
        guard Bundle.main.bundleIdentifier != nil else { return [] }
        return await UNUserNotificationCenter.current().pendingNotificationRequests().compactMap { request in
            guard request.identifier.hasPrefix(ScheduledReminder.prefix),
                let stamp = request.content.userInfo["due"] as? Double
            else { return nil }
            return ScheduledReminder(
                id: request.identifier, date: Date(timeIntervalSinceReferenceDate: stamp),
                title: request.content.title, body: request.content.body)
        }
    }
    func deliveredReminderIDs() async -> Set<String> {
        guard Bundle.main.bundleIdentifier != nil else { return [] }
        return Set(await UNUserNotificationCenter.current().deliveredNotifications().map { $0.request.identifier })
    }
    func schedule(_ reminder: ScheduledReminder) async throws {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = reminder.title; content.body = reminder.body; content.sound = .default
        content.userInfo = ["due": reminder.date.timeIntervalSinceReferenceDate]
        // The planner resolved local wall time (including DST) already. Pin that absolute instant,
        // so a timezone change does not silently retime an existing task.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.date)
        parts.calendar = utc; parts.timeZone = utc.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
    }
    func removeReminders(ids: [String]) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }
    func post(id: String, title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
