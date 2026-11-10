import Foundation
import Combine
import EventKit
import PerchReminders
import PlannerCore
import XCTest
@testable import PerchApp

@MainActor
final class FakeReminders: RemindersAccess {
    var hasAccess = true
    var records: [ReminderSyncRecord] = []
    var saves = 0
    var removals = 0
    var fetches = 0
    var onFetch: (() async -> Void)?
    func requestAccess() async throws {}
    func createCalendar() throws -> String { "synthetic-calendar" }
    func fetch(calendarID: String) async throws -> [ReminderSyncRecord] {
        fetches += 1
        await onFetch?()
        return records
    }
    func save(fields: ReminderFields, owner: ReminderOwner, calendarID: String, replacing: ReminderSyncRecord?) throws
        -> ReminderSyncRecord
    {
        if let replacing, !records.contains(replacing) { throw ReminderSyncError.stopped("conflict") }
        saves += 1
        let record = ReminderSyncRecord(
            id: replacing?.id ?? "synthetic-\(saves)", calendarID: calendarID, owner: owner, fields: fields,
            revision: "revision-\(saves)")
        records.removeAll { $0.id == record.id }; records.append(record)
        return record
    }
    func remove(_ expected: ReminderSyncRecord) throws { removals += 1; records.removeAll { $0.id == expected.id } }
    func completeFirst() {
        let old = records[0]; var fields = old.fields; fields.completed = true
        records[0] = ReminderSyncRecord(
            id: old.id, calendarID: old.calendarID, owner: old.owner, fields: fields, revision: "remote-completion")
    }
}

@MainActor
final class TestReminderLedger: ReminderLedgerStorage {
    var ledger = ReminderSyncLedger()
    func lock() throws {}
    func unlock() {}
    func load() throws -> ReminderSyncLedger { ledger }
    func save(_ ledger: ReminderSyncLedger) throws { self.ledger = ledger }
}

private final class ReminderScheduledAction: AppScheduledAction {
    var cancelled = false
    func cancel() { cancelled = true }
}

@MainActor
private final class ReminderTestScheduler: AppScheduling {
    var items: [(ReminderScheduledAction, @MainActor () -> Void)] = []
    var pending: Int { items.filter { !$0.0.cancelled }.count }
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> any AppScheduledAction {
        let item = ReminderScheduledAction(); items.append((item, action)); return item
    }
    func fire() {
        let current = items; items = []
        for (item, action) in current where !item.cancelled { action() }
    }
}

final class RemindersSyncTests: XCTestCase {
    @MainActor func testUndoAndRedoCancelPendingExportsAndPersistPause() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
        store.updatePrefs { $0.remindersSync = true }
        let id = try XCTUnwrap(
            store.send(.addTasks(["Synthetic"], day: nil, literal: true, agentID: nil))?.tasks.first?.id)
        let source = FakeReminders(), ledger = TestReminderLedger(), scheduler = ReminderTestScheduler()
        ledger.ledger.enabled = true
        let sync = RemindersSync(store: store, source: source, storage: ledger, scheduler: scheduler)
        await sync.reconcileNow()
        XCTAssertEqual(source.saves, 1)
        let owner = source.records[0].owner
        store.send(.rename(id, "Changed"))
        XCTAssertEqual(scheduler.pending, 1)
        store.undo(); scheduler.fire(); await sync.reconcileNow()
        XCTAssertEqual(source.saves, 1); XCTAssertEqual(source.removals, 0)
        XCTAssertFalse(ledger.ledger.enabled); XCTAssertNotNil(sync.lastError)
        XCTAssertTrue(store.canRedo)
        store.redo(); await sync.reconcileNow()
        XCTAssertEqual(source.saves, 1)
        let restarted = RemindersSync(store: store, source: source, storage: ledger, observing: false)
        await restarted.reconcileNow()
        XCTAssertEqual(source.saves, 1); XCTAssertNotNil(restarted.lastError)
        let granted = await sync.requestAccess(); XCTAssertTrue(granted)
        await sync.reconcileNow()
        XCTAssertEqual(source.saves, 2); XCTAssertEqual(source.records[0].owner, owner)
    }

    @MainActor func testBurstChangesCoalesceAndSelfNotificationsMakeNoWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
        store.updatePrefs { $0.remindersSync = true }
        let id = try XCTUnwrap(
            store.send(.addTasks(["Initial"], day: nil, literal: true, agentID: nil))?.tasks.first?.id)
        let source = FakeReminders(), ledger = TestReminderLedger(), scheduler = ReminderTestScheduler()
        ledger.ledger.enabled = true
        let sync = RemindersSync(store: store, source: source, storage: ledger, scheduler: scheduler)
        for title in ["One", "Two", "Three"] { store.send(.rename(id, title)) }
        XCTAssertEqual(scheduler.pending, 1)
        await sync.reconcileNow()
        XCTAssertEqual(source.saves, 1); XCTAssertEqual(source.records[0].fields.title, "Three")
        for _ in 0..<5 { NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil) }
        await Task.yield(); await Task.yield()
        XCTAssertEqual(scheduler.pending, 1)
        await sync.reconcileNow()
        XCTAssertEqual(source.saves, 1)
    }

    @MainActor func testUndoDuringSuspendedFetchPreventsWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
        store.updatePrefs { $0.remindersSync = true }
        let id = try XCTUnwrap(
            store.send(.addTasks(["Initial"], day: nil, literal: true, agentID: nil))?.tasks.first?.id)
        let source = FakeReminders(), ledger = TestReminderLedger()
        ledger.ledger.enabled = true
        let sync = RemindersSync(store: store, source: source, storage: ledger)
        source.onFetch = {
            store.send(.rename(id, "Edit")); store.undo()
        }
        await sync.reconcileNow()
        XCTAssertEqual(source.saves, 0); XCTAssertFalse(ledger.ledger.enabled)
        XCTAssertTrue(store.canRedo); XCTAssertNotNil(sync.lastError)
    }

    @MainActor func testNewInstallAndLegacyEnabledInstallNeedExplicitConsent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
        let source = FakeReminders(), ledger = TestReminderLedger()
        let sync = RemindersSync(store: store, source: source, storage: ledger, observing: false)
        XCTAssertFalse(store.prefs.remindersSync)
        store.updatePrefs { $0.remindersSync = true }
        _ = store.send(.addTasks(["Synthetic"], day: nil, literal: true, agentID: nil))
        await sync.reconcileNow()
        XCTAssertEqual(source.fetches, 0); XCTAssertEqual(source.saves, 0); XCTAssertNotNil(sync.lastError)
        let granted = await sync.requestAccess(); XCTAssertTrue(granted)
        await sync.reconcileNow()
        XCTAssertEqual(source.saves, 1)
    }

    @MainActor func testDayRolloverReconcilesEvenWhenTaskContentDidNotChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = PlannerStore(
            file: PlannerFile(url: root.appendingPathComponent("planner.json")), now: { now }, watching: false)
        store.beginApplication()
        store.updatePrefs { $0.remindersSync = true }
        _ = store.send(.addTasks(["Synthetic"], day: nil, literal: true, agentID: nil))
        let source = FakeReminders(), ledger = TestReminderLedger(), scheduler = ReminderTestScheduler()
        ledger.ledger.enabled = true
        let sync = RemindersSync(store: store, source: source, storage: ledger, scheduler: scheduler)
        await sync.reconcileNow()
        let tasks = store.planner.tasks
        now += 86_400
        store.advanceLifecycle()
        XCTAssertEqual(store.planner.tasks, tasks)
        XCTAssertEqual(scheduler.pending, 1)
        await sync.reconcileNow()
        XCTAssertEqual(source.removals, 1); XCTAssertTrue(source.records.isEmpty)
    }

    @MainActor func testEnablingSyncSchedulesFromPublishedNewPreference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
        _ = store.send(.addTasks(["Synthetic"], day: nil, literal: true, agentID: nil))
        let source = FakeReminders(), ledger = TestReminderLedger(), scheduler = ReminderTestScheduler()
        let sync = RemindersSync(store: store, source: source, storage: ledger, scheduler: scheduler)
        XCTAssertEqual(scheduler.pending, 0)
        let granted = await sync.requestAccess(); XCTAssertTrue(granted)
        store.updatePrefs { $0.remindersSync = true }
        XCTAssertEqual(scheduler.pending, 1)
        await sync.reconcileNow()
        XCTAssertEqual(source.saves, 1)
    }

    @MainActor func testDeleteUndoPreservesRemoteIdentityWithoutWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
        store.updatePrefs { $0.remindersSync = true }
        let id = try XCTUnwrap(
            store.send(.addTasks(["Synthetic"], day: nil, literal: true, agentID: nil))?.tasks.first?.id)
        let source = FakeReminders(), ledger = TestReminderLedger()
        ledger.ledger.enabled = true
        let sync = RemindersSync(store: store, source: source, storage: ledger)
        await sync.reconcileNow()
        let link = try XCTUnwrap(ledger.ledger.links[id])
        store.send(.delete(id)); store.undo()
        await sync.reconcileNow()
        XCTAssertEqual(ledger.ledger.links[id], link)
        XCTAssertEqual(source.saves, 1); XCTAssertEqual(source.removals, 0)
        XCTAssertEqual(store.planner.tasks[0].id, id)
        let granted = await sync.requestAccess(); XCTAssertTrue(granted)
        await sync.reconcileNow()
        XCTAssertEqual(source.saves, 1); XCTAssertEqual(source.records[0].id, link.remoteID)
    }

    @MainActor func testPermissionFailurePublishesWithoutPlannerMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
        store.updatePrefs { $0.remindersSync = true }
        _ = store.send(.addTasks(["Synthetic"], day: nil, literal: true, agentID: nil))
        let source = FakeReminders(), ledger = TestReminderLedger()
        ledger.ledger.enabled = true
        let sync = RemindersSync(store: store, source: source, storage: ledger, observing: false)
        await sync.reconcileNow()
        let before = try Data(contentsOf: store.file.url)
        var errors: [String] = []
        let subscription = sync.$lastError.compactMap { $0 }.sink { errors.append($0) }
        source.hasAccess = false
        await sync.reconcileNow()
        XCTAssertTrue(errors.contains { $0.contains("permission") })
        XCTAssertEqual(try Data(contentsOf: store.file.url), before)
        XCTAssertEqual(source.saves, 1)
        withExtendedLifetime(subscription) {}
    }

    @MainActor func testConcurrentPlannerWriterCannotBeOverwrittenByRemoteCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = PlannerFile(url: root.appendingPathComponent("planner.json"))
        let store = PlannerStore(file: file, watching: false)
        store.updatePrefs { $0.remindersSync = true }
        let id = try XCTUnwrap(
            store.send(.addTasks(["Synthetic"], day: nil, literal: true, agentID: nil))?.tasks.first?.id)
        let source = FakeReminders(), ledger = TestReminderLedger()
        ledger.ledger.enabled = true
        let sync = RemindersSync(store: store, source: source, storage: ledger, observing: false)
        await sync.reconcileNow(); source.completeFirst()
        source.onFetch = {
            let other = PlannerCommandPipeline(file: file)
            _ = try? other.execute(.rename(id, "External edit"), origin: .user)
        }
        await sync.reconcileNow()
        XCTAssertFalse(try file.load().tasks[0].done)
        XCTAssertEqual(try file.load().tasks[0].title, "External edit")
        XCTAssertNotNil(sync.lastError); XCTAssertEqual(source.saves, 1)
    }
}
