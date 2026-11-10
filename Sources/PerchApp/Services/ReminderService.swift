import Combine
import Foundation
import UserNotifications

// MARK: - Notifications

/// Notification permission and delivery. What rings, and when, is decided by `NotchTimelineDriver`.
@MainActor
final class ReminderService: NSObject, UNUserNotificationCenterDelegate {
    let store: PlannerStore
    @Published var notificationsAllowed = false

    init(store: PlannerStore) {
        self.store = store
        super.init()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            refreshAuthorization()
        }
    }

    func refreshAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            Task { @MainActor in self.notificationsAllowed = s.authorizationStatus == .authorized }
        }
    }

    func requestAuthorization() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        refreshAuthorization()
    }

    func notify(id: String, title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The notch already shows it; don't double up with a banner while the app is frontmost.
        [.sound]
    }
}
