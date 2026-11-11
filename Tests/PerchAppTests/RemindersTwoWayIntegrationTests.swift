import Combine
import Foundation
import PerchReminders
import PlannerCore
import XCTest
@testable import PerchApp

final class RemindersTwoWayIntegrationTests: XCTestCase {
    @MainActor private func exercise(
        _ body: (PlannerStore, FakeReminders, TestReminderLedger, RemindersSync) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
        _ = try XCTUnwrap(store.send(.addTasks(["Synthetic task"], day: nil, literal: true, agentID: nil)))
        store.updatePrefs { $0.remindersSync = true }
        let source = FakeReminders(), ledger = TestReminderLedger()
        ledger.ledger.enabled = true
        let sync = RemindersSync(store: store, source: source, storage: ledger, observing: false)
        try await body(store, source, ledger, sync)
    }
    @MainActor private func edit(_ source: FakeReminders, _ edit: (inout ReminderFields) -> Void) {
        let old = source.records[0]; var fields = old.fields; edit(&fields)
        source.records[0] = ReminderSyncRecord(
            id: old.id, calendarID: old.calendarID, owner: old.owner, fields: fields, revision: old.revision + "-remote"
        )
    }
    @MainActor func testInboxRoundTripAndModeChangePersistWithoutDeletingTask() async throws {
        for twoWay in [false, true] {
            try await exercise { store, source, ledger, sync in
                await sync.reconcileNow(); XCTAssertNil(sync.lastError)
                let id = store.planner.tasks[0].id
                let owner = source.records[0].owner
                _ = try XCTUnwrap(store.send(.move(id, .inbox)))
                await sync.reconcileNow(); XCTAssertNil(sync.lastError)
                XCTAssertNil(try store.file.load().tasks[0].day)
                XCTAssertTrue(source.records.isEmpty)
                XCTAssertEqual(ledger.ledger.links[id]?.retirement, .outOfScope)
                sync.setTwoWayEnabled(twoWay)
                let restarted = RemindersSync(store: store, source: source, storage: ledger, observing: false)
                await restarted.reconcileNow(); XCTAssertNil(restarted.lastError)
                _ = try XCTUnwrap(store.send(.move(id, .day(store.today))))
                await restarted.reconcileNow(); XCTAssertNil(restarted.lastError)
                await restarted.reconcileNow(); XCTAssertNil(restarted.lastError)
                XCTAssertEqual(try store.file.load().tasks[0].id, id)
                XCTAssertEqual(source.records.count, 1); XCTAssertEqual(source.records[0].owner, owner)
                XCTAssertEqual(source.saves, 2); XCTAssertEqual(source.removals, 1)
            }
        }
    }

    @MainActor func testModeRequiresSeparateConsentAndPersists() async throws {
        try await exercise { store, source, ledger, sync in
            XCTAssertFalse(sync.twoWayEnabled)
            await sync.reconcileNow()
            self.edit(source) { $0.title = "Remote" }
            await sync.reconcileNow()
            XCTAssertNotNil(sync.lastError); XCTAssertEqual(store.planner.tasks[0].title, "Synthetic task")
            sync.setTwoWayEnabled(true); await sync.reconcileNow()
            XCTAssertNil(sync.lastError); XCTAssertEqual(try store.file.load().tasks[0].title, "Remote")
            XCTAssertTrue(ledger.ledger.twoWayEnabled)
            let restarted = RemindersSync(store: store, source: source, storage: ledger, observing: false)
            XCTAssertTrue(restarted.twoWayEnabled)
            await restarted.reconcileNow(); XCTAssertEqual(source.saves, 1)
        }
    }
    @MainActor func testDisabledOrUnauthorizedModeCannotOptIn() async throws {
        try await exercise { store, source, ledger, sync in
            store.updatePrefs { $0.remindersSync = false }
            sync.setTwoWayEnabled(true); XCTAssertFalse(ledger.ledger.twoWayEnabled)
            store.updatePrefs { $0.remindersSync = true }; source.hasAccess = false
            sync.setTwoWayEnabled(true); XCTAssertFalse(ledger.ledger.twoWayEnabled)
            XCTAssertNotNil(sync.lastError); XCTAssertEqual(source.saves, 0)
        }
    }
    @MainActor func testRemoteCompletionReopenAndDeletePersistThroughCommands() async throws {
        try await exercise { store, source, ledger, sync in
            sync.setTwoWayEnabled(true); await sync.reconcileNow()
            source.completeFirst(); await sync.reconcileNow()
            XCTAssertTrue(try store.file.load().tasks[0].done)
            self.edit(source) { $0.completed = false }; await sync.reconcileNow()
            XCTAssertFalse(try store.file.load().tasks[0].done)
            let id = store.planner.tasks[0].id
            source.records = []; await sync.reconcileNow()
            XCTAssertTrue(try store.file.load().tasks.isEmpty)
            XCTAssertTrue(ledger.ledger.links[id]!.retired)
            XCTAssertNil(sync.lastError)
        }
    }
    @MainActor func testDisjointChangesMergeAndSameFieldConflictIsVisible() async throws {
        try await exercise { store, source, _, sync in
            sync.setTwoWayEnabled(true); await sync.reconcileNow()
            let id = store.planner.tasks[0].id
            _ = store.send(.rename(id, "Local")); self.edit(source) { $0.notes = "Remote note" }
            await sync.reconcileNow()
            XCTAssertEqual(try store.file.load().tasks[0].notes, "Remote note")
            XCTAssertEqual(source.records[0].fields.title, "Local")
            _ = store.send(.rename(id, "Next local")); self.edit(source) { $0.title = "Next remote" }
            await sync.reconcileNow()
            XCTAssertNotNil(sync.lastError)
            XCTAssertEqual(try store.file.load().tasks[0].title, "Next local")
            XCTAssertEqual(source.records[0].fields.title, "Next remote")
        }
    }
    @MainActor func testConcurrentDiskWriterPreventsTwoWayImport() async throws {
        try await exercise { store, source, _, sync in
            sync.setTwoWayEnabled(true); await sync.reconcileNow()
            let id = store.planner.tasks[0].id
            self.edit(source) { $0.title = "Remote" }
            source.onFetch = {
                let other = PlannerCommandPipeline(file: store.file)
                _ = try? other.execute(.rename(id, "Concurrent"), origin: .user)
            }
            await sync.reconcileNow()
            XCTAssertEqual(try store.file.load().tasks[0].title, "Concurrent")
            XCTAssertNotNil(sync.lastError); XCTAssertEqual(source.saves, 1)
        }
    }
    @MainActor func testRemoteDatesRoundTripThroughPlannerActions() async throws {
        try await exercise { store, source, _, sync in
            sync.setTwoWayEnabled(true); await sync.reconcileNow()
            let next = store.today.adding(days: 2)
            self.edit(source) { $0.due = Calendar.current.dateComponents([.year, .month, .day], from: next.date()) }
            await sync.reconcileNow()
            XCTAssertEqual(try store.file.load().tasks[0].day, next)
            self.edit(source) { $0.due = nil }; await sync.reconcileNow()
            XCTAssertNil(try store.file.load().tasks[0].day); XCTAssertNil(sync.lastError)
        }
    }
    @MainActor func testFutureCompletionIsRejectedByRealPlannerWithoutChangingDisk() async throws {
        try await exercise { store, source, _, sync in
            let id = store.planner.tasks[0].id, day = store.today.adding(days: 1)
            _ = try XCTUnwrap(store.send(.move(id, .day(day))))
            sync.setTwoWayEnabled(true); await sync.reconcileNow()
            let before = try Data(contentsOf: store.file.url)
            source.completeFirst(); await sync.reconcileNow()
            XCTAssertEqual(try Data(contentsOf: store.file.url), before)
            XCTAssertNotNil(sync.lastError); XCTAssertEqual(source.saves, 1)
        }
    }
    @MainActor func testUndoPausesBothDirections() async throws {
        try await exercise { store, source, ledger, _ in
            ledger.ledger.twoWayEnabled = true
            let sync = RemindersSync(store: store, source: source, storage: ledger)
            await sync.reconcileNow()
            let id = store.planner.tasks[0].id
            _ = store.send(.rename(id, "Changed")); store.undo()
            self.edit(source) { $0.notes = "Remote" }; await sync.reconcileNow()
            XCTAssertFalse(ledger.ledger.enabled); XCTAssertNotNil(sync.lastError)
            XCTAssertEqual(try store.file.load().tasks[0].notes, "")
        }
    }
}
