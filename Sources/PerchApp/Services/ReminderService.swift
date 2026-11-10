import Combine
import Foundation
import UserNotifications

// MARK: - Notifications

/// Notification permission and delivery. What rings, and when, is decided by `NotchTimelineDriver`.
@MainActor
final class ReminderService: NSObject, UNUserNotificationCenterDelegate {
    let store: PlannerStore
    @Published var notificationsAllowed = false

    private let source: any NotificationAccess

    init(store: PlannerStore, source: (any NotificationAccess)? = nil) {
        self.store = store
        self.source = source ?? SystemNotificationAccess()
        super.init()
        self.source.setDelegate(self)
        refreshAuthorization()
    }

    func refreshAuthorization() {
        Task { @MainActor in notificationsAllowed = await source.isAuthorized() }
    }

    func requestAuthorization() async {
        _ = try? await source.requestAuthorization()
        notificationsAllowed = await source.isAuthorized()
    }

    func notify(id: String, title: String, body: String) {
        source.post(id: id, title: title, body: body)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The notch already shows it; don't double up with a banner while the app is frontmost.
        [.sound]
    }
}
