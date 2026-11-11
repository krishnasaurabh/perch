import Combine
import Foundation
import PerchUI
import PlannerCore
import UserNotifications
import XCTest
@testable import PerchApp

@MainActor
private final class ScheduleCenter: NotificationAccess {
    var authorized = true
    var pending: [String: ScheduledReminder] = [:]
    var delivered = Set<String>()
    var additions = 0
    var immediatePosts = 0
    var reject = false
    var onQuery: (() -> Void)?
    func setDelegate(_ delegate: any UNUserNotificationCenterDelegate) {}
    func isAuthorized() async -> Bool { onQuery?(); onQuery = nil; return authorized }
    func requestAuthorization() async throws {}
    func post(id: String, title: String, body: String) { immediatePosts += 1 }
    func pendingReminders() async -> [ScheduledReminder] { Array(pending.values) }
    func deliveredReminderIDs() async -> Set<String> { delivered }
    func schedule(_ reminder: ScheduledReminder) async throws {
        if reject { throw NSError(domain: "SyntheticSchedulingFailure", code: 1) }
        additions += 1; pending[reminder.id] = reminder
    }
    func removeReminders(ids: [String]) {
        for id in ids { pending[id] = nil; delivered.remove(id) }
    }
}

private final class ReminderTime { var now = Date(timeIntervalSince1970: 1_800_000_000) }

@MainActor
private final class ReminderFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let time = ReminderTime()
    let source = ScheduleCenter()
    let store: PlannerStore
    let service: ReminderService
    init() {
        let clock = time
        store = PlannerStore(
            file: PlannerFile(url: root.appendingPathComponent("planner.json")),
            now: { clock.now }, watching: false)
        service = ReminderService(
            store: store, source: source, clock: ClosurePlannerClock { clock.now }, observing: false)
    }
    func task() -> UUID {
        let id = store.send(.addTasks(["Scheduled fixture"], day: nil, literal: true, agentID: nil))!.tasks[0].id
        store.updateTask(id) { $0.remindAt = time.now.addingTimeInterval(600) }
        return id
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

final class ReminderServiceTests: XCTestCase {
    @MainActor
    func testSchedulingSurvivesServiceRelaunchWithoutDuplicates() async throws {
        let f = ReminderFixture(); defer { f.clean() }; _ = f.task()
        await f.service.reconcile()
        XCTAssertEqual(f.source.pending.count, 1)
        let first = f.source.pending
        let next = ReminderService(
            store: f.store, source: f.source,
            clock: ClosurePlannerClock { f.time.now }, observing: false)
        await next.reconcile()
        XCTAssertEqual(f.source.pending, first)
        XCTAssertEqual(f.source.additions, 1)
        XCTAssertEqual(f.source.immediatePosts, 0)
        XCTAssertEqual(next.records.values.first?.state, .scheduled)
    }

    @MainActor
    func testEditsSnoozeCompletionUndoAndDeletionReconcileExactIDs() async throws {
        let f = ReminderFixture(); defer { f.clean() }; let id = f.task()
        await f.service.reconcile(); let first = try XCTUnwrap(f.source.pending.values.first)
        f.store.updateTask(id) { $0.title = "Renamed fixture" }
        await f.service.reconcile()
        XCTAssertEqual(f.source.pending[first.id]?.title, "Renamed fixture")
        f.store.updateTask(id) { $0.remindAt = f.time.now.addingTimeInterval(1200) }
        await f.service.reconcile()
        XCTAssertNil(f.source.pending[first.id]); XCTAssertEqual(f.source.pending.count, 1)
        f.store.send(.complete(id)); await f.service.reconcile()
        XCTAssertTrue(f.source.pending.isEmpty)
        f.store.undo(); await f.service.reconcile()
        XCTAssertEqual(f.source.pending.count, 1)
        f.store.send(.delete(id)); await f.service.reconcile()
        XCTAssertTrue(f.source.pending.isEmpty)
    }

    @MainActor
    func testSleepWakePersistsUnknownMissedWithoutImmediateNotification() async throws {
        let f = ReminderFixture(); defer { f.clean() }; _ = f.task()
        await f.service.reconcile(); let id = try XCTUnwrap(f.source.pending.keys.first)
        f.time.now += 720
        await f.service.reconcile()
        XCTAssertTrue(f.source.pending.isEmpty)
        XCTAssertEqual(f.service.records[id]?.state, .missed)
        f.time.now -= 720
        await f.service.reconcile()
        XCTAssertTrue(f.source.pending.isEmpty)
        XCTAssertEqual(f.source.additions, 1)
        XCTAssertEqual(f.source.immediatePosts, 0)
    }

    @MainActor
    func testObservedDeliveryWhileQuitIsNotReplayed() async throws {
        let f = ReminderFixture(); defer { f.clean() }; _ = f.task()
        await f.service.reconcile(); let id = try XCTUnwrap(f.source.pending.keys.first)
        f.source.pending[id] = nil; f.source.delivered.insert(id); f.time.now += 720
        let next = ReminderService(
            store: f.store, source: f.source,
            clock: ClosurePlannerClock { f.time.now }, observing: false)
        await next.reconcile()
        XCTAssertEqual(next.records[id]?.state, .delivered)
        f.source.delivered.removeAll(); f.time.now -= 720
        await next.reconcile()
        XCTAssertTrue(f.source.pending.isEmpty)
        XCTAssertEqual(f.source.additions, 1)
    }

    @MainActor
    func testDeniedAndSchedulingFailureCanRetryWithoutLosingReminder() async throws {
        let f = ReminderFixture(); defer { f.clean() }; _ = f.task()
        f.source.authorized = false; await f.service.reconcile()
        XCTAssertFalse(f.service.notificationsAllowed); XCTAssertTrue(f.source.pending.isEmpty)
        f.source.authorized = true; f.source.reject = true; await f.service.reconcile()
        XCTAssertNotNil(f.service.lastError)
        XCTAssertFalse(f.service.records.values.contains { $0.state == .scheduled })
        f.source.reject = false; await f.service.reconcile()
        XCTAssertNil(f.service.lastError); XCTAssertEqual(f.source.pending.count, 1)
    }

    @MainActor
    func testCorruptLedgerFailsClosedWithoutOverwritingIt() async throws {
        let f = ReminderFixture(); defer { f.clean() }; _ = f.task()
        let url = f.store.file.url.appendingPathExtension("notifications.json")
        let corrupt = Data("not valid json".utf8)
        try corrupt.write(to: url)
        await f.service.reconcile()
        XCTAssertNotNil(f.service.lastError); XCTAssertTrue(f.source.pending.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    @MainActor
    func testEditDuringAwaitedAuthorizationUsesLatestPlanner() async throws {
        let f = ReminderFixture(); defer { f.clean() }; let id = f.task()
        f.source.onQuery = { f.store.send(.delete(id)) }
        await f.service.reconcile()
        XCTAssertTrue(f.source.pending.isEmpty)
        XCTAssertEqual(f.source.additions, 0)
    }

    @MainActor
    func testNativeRequestUsesOneShotUTCTriggerWithoutAccessingCenter() async throws {
        let instant = Date(timeIntervalSince1970: 1_800_000_000.25)
        let reminder = ScheduledReminder(
            id: ScheduledReminder.prefix + "fixture", date: instant, title: "Fixture", body: "Body")
        let request = SystemNotificationAccess.request(for: reminder)
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertFalse(trigger.repeats)
        XCTAssertEqual(request.identifier, reminder.id)
        XCTAssertEqual(request.content.title, reminder.title)
        XCTAssertEqual(request.content.body, reminder.body)
        XCTAssertNotNil(request.content.sound)
        XCTAssertEqual(trigger.dateComponents.timeZone?.secondsFromGMT(), 0)
        let date = try XCTUnwrap(trigger.dateComponents.calendar?.date(from: trigger.dateComponents))
        XCTAssertEqual(date.timeIntervalSince1970, 1_800_000_001)
        XCTAssertEqual(request.content.userInfo["due"] as? Double, instant.timeIntervalSinceReferenceDate)
    }

    @MainActor
    func testLaunchAndLogicalRolloverMaterializeHorizonWithoutViews() async throws {
        let f = ReminderFixture(); defer { f.clean() }; let id = f.task()
        f.store.updatePrefs { $0.resetHour = 4 }
        var edit = TaskEdit(); edit.repeatRule = TaskRepeat(unit: .day, interval: 2).description
        XCTAssertNotNil(f.store.send(.update(id, edit)))
        f.store.beginApplication()
        let before = f.store.planner.tasks
        XCTAssertEqual(before.count, 7)
        f.store.beginApplication()
        XCTAssertEqual(f.store.planner.tasks, before)
        f.time.now += 2 * 86_400
        f.store.advanceLifecycle()
        XCTAssertEqual(f.store.planner.tasks.count, 8)
        let anchor = try XCTUnwrap(before.first?.day)
        for task in f.store.planner.tasks {
            let offset = Calendar.current.dateComponents([.day], from: anchor.date(), to: task.day!.date()).day!
            XCTAssertEqual(offset % 2, 0)
            XCTAssertEqual(
                Calendar.current.component(.hour, from: task.remindAt!),
                Calendar.current.component(.hour, from: before[0].remindAt!))
        }
    }

    @MainActor
    func testRolloverWaitsForResetHourAndDoesNotResurrectDeletedOccurrence() async throws {
        let f = ReminderFixture(); defer { f.clean() }
        f.store.updatePrefs {
            $0.resetHour = 4; $0.carryMode = .never
        }
        let day = f.store.today
        f.time.now = day.adding(days: 1).start(resetHour: 4).addingTimeInterval(-120)
        let id = f.task()
        var reminder = TaskChanges(); reminder.remindAt = .set(f.time.now.addingTimeInterval(60))
        XCTAssertNotNil(f.store.send(.editTask(id, reminder)))
        var edit = TaskEdit(); edit.repeatRule = "daily"
        XCTAssertNotNil(f.store.send(.update(id, edit)))
        f.store.beginApplication()
        XCTAssertEqual(f.store.today, day)
        XCTAssertEqual(f.store.planner.tasks.count, 14)
        let future = try XCTUnwrap(f.store.planner.tasks.first { $0.day == day.adding(days: 3) })
        XCTAssertEqual(future.remindAt, day.adding(days: 4).start(resetHour: 4).addingTimeInterval(-60))
        f.store.send(.delete(future.id))
        f.store.renewReminderHorizon()
        XCTAssertFalse(f.store.planner.tasks.contains { $0.id == future.id || $0.day == future.day })
        f.time.now += 120
        f.store.advanceLifecycle()
        XCTAssertEqual(f.store.today, day.adding(days: 1))
        XCTAssertTrue(f.store.planner.tasks.contains { $0.day == day.adding(days: 14) })
        XCTAssertFalse(f.store.planner.tasks.contains { $0.day == future.day })
    }

    @MainActor
    func testChangingRepeatRuleRenewsThroughSubscriptionWithoutChangingReminder() async throws {
        let f = ReminderFixture(); defer { f.clean() }; let id = f.task()
        let service = ReminderService(
            store: f.store, source: f.source,
            clock: ClosurePlannerClock { f.time.now }, observing: true)
        await service.reconcile()
        let expanded = expectation(description: "Repeat edit renews the horizon")
        let token = f.store.$planner.first(where: { $0.tasks.count == 14 }).sink { _ in expanded.fulfill() }
        var edit = TaskEdit(); edit.repeatRule = "daily"
        XCTAssertNotNil(f.store.send(.update(id, edit)))
        await fulfillment(of: [expanded], timeout: 3)
        await service.reconcile()
        XCTAssertEqual(f.source.pending.count, 14)
        withExtendedLifetime(token) {}
    }

    @MainActor
    func testCompletionRelativeRepeatsAreNotExpandedBeforeCompletion() async throws {
        let f = ReminderFixture(); defer { f.clean() }; let id = f.task()
        var edit = TaskEdit(); edit.repeatRule = TaskRepeat(unit: .day, fromCompletion: true).description
        XCTAssertNotNil(f.store.send(.update(id, edit)))
        f.store.beginApplication()
        XCTAssertEqual(f.store.planner.tasks.count, 1)
        f.store.send(.complete(id))
        f.store.renewReminderHorizon()
        XCTAssertEqual(f.store.planner.tasks.count, 2)
    }
}
