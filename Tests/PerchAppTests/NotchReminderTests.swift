import Combine
import Foundation
import PerchUI
import PlannerCore
import UserNotifications
import XCTest
@testable import PerchApp

@MainActor
private final class NotchNotificationSource: NotificationAccess {
    var pending: [String: ScheduledReminder] = [:]
    var posts = 0
    func setDelegate(_ delegate: any UNUserNotificationCenterDelegate) {}
    func isAuthorized() async -> Bool { true }
    func requestAuthorization() async throws {}
    func post(id: String, title: String, body: String) { posts += 1 }
    func pendingReminders() async -> [ScheduledReminder] { Array(pending.values) }
    func deliveredReminderIDs() async -> Set<String> { [] }
    func schedule(_ reminder: ScheduledReminder) async throws { pending[reminder.id] = reminder }
    func removeReminders(ids: [String]) { for id in ids { pending[id] = nil } }
}

private final class NotchReminderTime { var now = Date(timeIntervalSince1970: 1_800_000_000) }

final class NotchReminderTests: XCTestCase {
    @MainActor
    func testStripStartAcknowledgesOnlyTheAnsweredClosedReminder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        let day = PlannerEngine(planner: Planner(), now: { now }).today
        let first = PlanTask(title: "Call the bank", day: day, remindAt: now.addingTimeInterval(-2))
        let second = PlanTask(title: "Book the appointment", day: day, remindAt: now.addingTimeInterval(-1))
        try file.mutate { $0.tasks = [first, second] }
        let store = PlannerStore(file: file, now: { now }, watching: false)
        let model = NotchModel(); model.screenID = 1
        let strips = NotchStrips(store: store, model: model, now: { now }); model.strips = strips
        model.closedReminderIDs = [first.id, second.id]
        let activity = try XCTUnwrap(strips.currentActivity)
        XCTAssertEqual(activity.taskID, first.id)
        var invalid = activity; invalid.taskID = UUID()
        XCTAssertFalse(strips.answer(.start, activity: invalid), "A failed answer must keep the waiting indicator")
        XCTAssertEqual(model.closedReminderIDs, [first.id, second.id])
        XCTAssertTrue(strips.answer(.start, activity: activity))
        XCTAssertEqual(store.planner.focus?.taskID, first.id)
        XCTAssertEqual(store.planner.focus?.state, .running)
        XCTAssertFalse(try XCTUnwrap(store.planner.tasks.first { $0.id == first.id }).done)
        XCTAssertEqual(store.planner.tasks.first { $0.id == first.id }?.remindAt, first.remindAt)
        XCTAssertEqual(model.closedReminderIDs, [second.id], "Starting a block answers just that reminder")
        XCTAssertEqual(strips.currentActivity?.taskID, second.id)
        XCTAssertTrue(model.closed(in: store, screenID: 1, now: now).reminder)
        XCTAssertTrue(strips.answer(.notToday, activity: try XCTUnwrap(strips.currentActivity)))
        strips.refresh()
        XCTAssertTrue(model.closedReminderIDs.isEmpty)
        XCTAssertNil(strips.currentActivity)
        XCTAssertFalse(model.closed(in: store, screenID: 1, now: now).reminder)
        let request = ScheduledReminder(task: first)
        model.refreshMissedReminder(
            planner: store.planner, records: [request.id: .init(date: request.date, state: .missed)], now: now)
        XCTAssertNil(model.missedReminder, "Delivery reconciliation cannot resurrect the answered occurrence")
    }

    @MainActor
    func testStripSnoozeAcknowledgesTheOldOccurrenceNotItsNewDueTime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let time = NotchReminderTime()
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        let day = PlannerEngine(planner: Planner(), now: { time.now }).today
        try file.mutate {
            $0.tasks = [PlanTask(title: "Call the bank", day: day, remindAt: time.now)]
        }
        let store = PlannerStore(file: file, now: { time.now }, watching: false)
        let model = NotchModel()
        let strips = NotchStrips(store: store, model: model, now: { time.now }); model.strips = strips
        XCTAssertTrue(strips.answer(.snooze, activity: try XCTUnwrap(strips.currentActivity)))
        XCTAssertTrue(model.closedReminderIDs.isEmpty)
        let task = try XCTUnwrap(store.planner.tasks.first)
        let request = ScheduledReminder(task: task)
        time.now = request.date.addingTimeInterval(120)
        model.refreshMissedReminder(
            planner: store.planner, records: [request.id: .init(date: request.date, state: .missed)], now: time.now)
        XCTAssertEqual(model.missedReminder?.kind, .reminder(task.id), "The snoozed occurrence is still answerable")
    }

    @MainActor
    func testMissedCardOutlivesTransientExpiryAndDismissesOnlyItsOccurrence() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var task = PlanTask(title: "Synthetic reminder", day: "2027-01-15", remindAt: now.addingTimeInterval(-120))
        var planner = Planner(); planner.tasks = [task]
        let request = ScheduledReminder(task: task)
        let records = [request.id: ReminderRecord(date: request.date, state: .missed)]
        let model = NotchModel()
        let transient = PresentedNotchActivity(kind: .reminder(task.id), title: task.title, subtitle: "Due now")
        model.show(transient)
        model.refreshMissedReminder(planner: planner, records: records, now: now)
        XCTAssertEqual(model.displayedActivity?.id, transient.id)
        model.dismissActivity()  // Automatic timeline expiry is not an explicit dismissal.
        XCTAssertEqual(model.displayedActivity?.kind, .reminder(task.id))
        XCTAssertEqual(model.displayedActivity?.subtitle, "Missed reminder · delivery unconfirmed")
        let stableID = model.displayedActivity?.id
        model.refreshMissedReminder(planner: planner, records: records, now: now)
        XCTAssertEqual(model.displayedActivity?.id, stableID)
        model.close(); model.open(pinned: true)
        XCTAssertEqual(model.displayedActivity?.id, stableID)
        model.dismissPresentedActivity(in: planner)
        model.refreshMissedReminder(planner: planner, records: records, now: now)
        XCTAssertNil(model.displayedActivity)

        // A new occurrence is not hidden by dismissal of the old due instant.
        task.remindAt = now.addingTimeInterval(-90); planner.tasks = [task]
        let next = ScheduledReminder(task: task)
        model.refreshMissedReminder(
            planner: planner, records: [next.id: .init(date: next.date, state: .missed)], now: now)
        XCTAssertEqual(model.displayedActivity?.kind, .reminder(task.id))
        task.done = true; planner.tasks = [task]
        model.refreshMissedReminder(
            planner: planner, records: [next.id: .init(date: next.date, state: .missed)], now: now)
        XCTAssertNil(model.displayedActivity)
    }

    @MainActor
    func testExplicitTransientDismissalAlsoSuppressesLaterMissedCard() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let task = PlanTask(title: "Synthetic reminder", day: "2027-01-15", remindAt: now)
        var planner = Planner(); planner.tasks = [task]
        let request = ScheduledReminder(task: task)
        let model = NotchModel()
        model.show(.init(kind: .reminder(task.id), title: task.title, subtitle: "Due now"))
        model.dismissPresentedActivity(in: planner)
        model.refreshMissedReminder(
            planner: planner, records: [request.id: .init(date: now, state: .missed)],
            now: now.addingTimeInterval(120))
        XCTAssertNil(model.displayedActivity)
    }

    @MainActor
    func testOwnerReconciliationPublishesMissedCardAfterGraceAndLateWake() async throws {
        for delay in [60.0, 7200] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let time = NotchReminderTime()
            let store = PlannerStore(
                file: PlannerFile(url: root.appendingPathComponent("planner.json")), now: { time.now }, watching: false)
            let task = try XCTUnwrap(
                store.apply { try $0.addTasks(["Synthetic scheduled reminder"], on: .day($0.today)) }?.first)
            store.updateTask(task.id) { $0.remindAt = time.now.addingTimeInterval(600) }
            let due = try XCTUnwrap(store.planner.tasks.first?.remindAt)
            let source = NotchNotificationSource()
            let owner = ReminderService(
                store: store, source: source, clock: ClosurePlannerClock { time.now }, observing: false)
            let model = NotchModel()
            let observation = NotchReminderObservation(store: store, reminders: owner, model: model, now: { time.now })
            await owner.reconcile()
            XCTAssertEqual(source.pending.count, 1)
            XCTAssertNil(model.displayedActivity)
            time.now = due.addingTimeInterval(delay)
            let visible = expectation(description: "Owner outcome updates missed presentation")
            visible.assertForOverFulfill = false
            let subscription = model.$missedReminder.compactMap { $0 }.sink { _ in visible.fulfill() }
            await owner.reconcile()
            await fulfillment(of: [visible], timeout: 2)
            XCTAssertEqual(model.displayedActivity?.kind, .reminder(task.id))
            XCTAssertEqual(owner.records.values.first?.state, .missed)
            XCTAssertTrue(source.pending.isEmpty)
            XCTAssertEqual(source.posts, 0)

            // Repeated successful nil outcomes must not undo an explicit dismissal.
            model.dismissPresentedActivity(in: store.planner)
            let remainsDismissed = expectation(description: "Dismissal survives reconciliation")
            remainsDismissed.isInverted = true
            let dismissedSubscription = model.$missedReminder.compactMap { $0 }.sink { _ in remainsDismissed.fulfill() }
            await owner.reconcile()
            await fulfillment(of: [remainsDismissed], timeout: 0.1)
            XCTAssertNil(model.displayedActivity)
            withExtendedLifetime((observation, subscription, dismissedSubscription)) {}
        }
    }
}
