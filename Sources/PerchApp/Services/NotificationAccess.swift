import Foundation
import UserNotifications

@MainActor
protocol NotificationAccess {
    func setDelegate(_ delegate: any UNUserNotificationCenterDelegate)
    func isAuthorized() async -> Bool
    func requestAuthorization() async throws
    func post(id: String, title: String, body: String)
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
    func post(id: String, title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
