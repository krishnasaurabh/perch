import AppKit
import Combine
import Foundation
import PerchUI
import PlannerCore
import UserNotifications

/// Owns OS reminder scheduling independently of the notch's short presentation windows.
/// Accepted requests survive app exit. OS delivery, sleep behavior and Focus remain best effort.
@MainActor
final class ReminderService: NSObject, UNUserNotificationCenterDelegate {
    let store: PlannerStore
    @Published var notificationsAllowed = false
    @Published private(set) var lastError: String?
    private(set) var records: [String: ReminderRecord] = [:]

    private let source: any NotificationAccess
    private let clock: any PlannerClock
    private let ledger: ReminderLedger
    private let observing: Bool
    private var subscriptions = Set<AnyCancellable>()
    private var renewal: Timer?
    private var worker: Task<Void, Never>?
    private var dirty = false
    private var generation = 0
    private var observedDeliveries = Set<String>()

    init(
        store: PlannerStore, source: (any NotificationAccess)? = nil,
        clock: any PlannerClock = SystemPlannerClock(), ledgerURL: URL? = nil, observing: Bool = true
    ) {
        self.store = store
        self.source = source ?? SystemNotificationAccess()
        self.clock = clock
        self.ledger = ReminderLedger(url: ledgerURL ?? store.file.url.appendingPathExtension("notifications.json"))
        self.observing = observing
        super.init()
        self.source.setDelegate(self)
        if observing { start() }
    }

    private func start() {
        let alarms = store.$planner.map { NotchActivityTimeline.triggers(planner: $0) }.removeDuplicates().map { _ in ()
        }
        let reset = store.$planner.map { $0.preferences.resetHour }.removeDuplicates().map { _ in () }
        alarms.merge(with: reset).receive(on: RunLoop.main).sink { [weak self] in self?.requestRefresh() }
            .store(in: &subscriptions)
        for name in [
            Notification.Name.NSCalendarDayChanged, .NSSystemClockDidChange,
            NSNotification.Name.NSSystemTimeZoneDidChange,
        ] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.requestRefresh() }.store(in: &subscriptions)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name).receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.requestRefresh() }.store(in: &subscriptions)
        }
        requestRefresh()
    }

    func refreshAuthorization() { requestRefresh() }

    func requestAuthorization() async {
        do { try await source.requestAuthorization() } catch {
            lastError = "Notification permission failed: \(error.localizedDescription)"
        }
        await reconcile()
    }

    func notify(id: String, title: String, body: String) {
        source.post(id: id, title: title, body: body)
    }

    private func requestRefresh() {
        dirty = true; generation += 1
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.dirty {
                self.dirty = false
                await self.reconcilePass()
            }
            self.worker = nil
        }
    }

    /// Serializes concurrent launch/edit/wake passes; useful with a fake center and clock in tests.
    func reconcile() async {
        requestRefresh()
        while let worker { await worker.value }
    }

    private func reconcilePass() async {
        renewal?.invalidate(); renewal = nil
        defer { if observing { scheduleRenewal() } }
        store.advanceLifecycle()
        store.renewReminderHorizon()
        let version = generation
        let planner = store.planner
        do {
            var history = try ledger.load()
            let allowed = await source.isAuthorized()
            let pending = await source.pendingReminders()
            let delivered = await source.deliveredReminderIDs().union(observedDeliveries)
            guard version == generation, planner == store.planner else { requestRefresh(); return }
            notificationsAllowed = allowed
            let plan = ReminderSchedule.reconcile(
                planner: planner, now: clock.now, calendar: store.engine.calendar,
                pending: pending, delivered: delivered, records: history, authorized: allowed)
            history = plan.records
            // Save terminal decisions before removing requests. A failed ledger write cannot silently re-arm them.
            try ledger.save(history)
            source.removeReminders(ids: plan.remove)
            let existing = Dictionary(pending.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for request in plan.requests {
                guard version == generation else { return }
                if existing[request.id] != request {
                    // A wake or suspended async call may have crossed the due instant. Never replay as an immediate alert.
                    guard request.date > clock.now else { continue }
                    try await source.schedule(request)
                }
                history[request.id] = ReminderRecord(date: request.date, state: .scheduled)
            }
            try ledger.save(history)
            records = history
            observedDeliveries.subtract(delivered)
            if store.lastError == lastError { store.lastError = nil }
            lastError = nil
        } catch {
            let message = "Reminder scheduling failed: \(error.localizedDescription)"
            lastError = message
            store.lastError = message
        }
    }

    private func scheduleRenewal() {
        let now = clock.now
        let engine = store.engine
        let dayEnd = engine.today.adding(days: 1, calendar: engine.calendar)
            .start(resetHour: store.prefs.resetHour, calendar: engine.calendar)
        // Renew after due instants too, to free OS capacity and record unresolved delivery.
        let boundaries = store.planner.tasks.filter { !$0.done && $0.day != nil }.compactMap(\.remindAt)
            .map { $0.addingTimeInterval(ReminderSchedule.deliveryGrace) }.filter { $0 > now }
        let next = min(dayEnd, boundaries.min() ?? dayEnd, now.addingTimeInterval(3600))
        let timer = Timer(fire: max(next, now.addingTimeInterval(1)), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.requestRefresh() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        renewal = timer
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await recordDelivery(notification.request.identifier)
        // The notch provides the foreground card. Only the OS sound plays, never a second app sound.
        return [.sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        await recordDelivery(response.notification.request.identifier)
    }

    private func recordDelivery(_ id: String) {
        guard id.hasPrefix(ScheduledReminder.prefix) else { return }
        observedDeliveries.insert(id)
        requestRefresh()
    }
}
