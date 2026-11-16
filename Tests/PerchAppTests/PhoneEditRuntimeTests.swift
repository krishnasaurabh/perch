import Foundation
import PerchReminders
import PlannerCore
import XCTest
@testable import PerchApp

private final class PhoneEditScheduledAction: AppScheduledAction { func cancel() {} }
@MainActor
private struct PhoneEditScheduler: AppScheduling {
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> any AppScheduledAction {
        PhoneEditScheduledAction()
    }
}

final class PhoneEditRuntimeTests: XCTestCase {
    @MainActor
    private func exercise(
        _ body: (PlannerStore, FakeReminders, TestReminderLedger, RemindersSync) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
        XCTAssertNotNil(store.send(.addTasks(["Synthetic task"], day: nil, literal: true, agentID: nil)))
        store.updatePrefs { $0.remindersSync = true }
        let source = FakeReminders(), ledger = TestReminderLedger()
        ledger.ledger.enabled = true
        let sync = RemindersSync(
            store: store, source: source, storage: ledger, scheduler: PhoneEditScheduler())
        await sync.reconcileNow()
        try await body(store, source, ledger, sync)
    }

    @MainActor
    private func edit(_ source: FakeReminders, title: String) {
        let old = source.records[0]
        var fields = old.fields; fields.title = title
        source.records[0] = ReminderSyncRecord(
            id: old.id, calendarID: old.calendarID, owner: old.owner, fields: fields, revision: old.revision + "-edit")
    }

    @MainActor
    func testDefaultIgnoreRejectsTextButPreservesStandardTodaysCompletion() async throws {
        try await exercise { store, source, ledger, sync in
            XCTAssertEqual(store.prefs.phoneEdits, .ignore)
            self.edit(source, title: "Phone title")
            await sync.reconcileNow()
            XCTAssertEqual(try store.file.load().tasks[0].title, "Synthetic task")
            XCTAssertEqual(source.records[0].fields.title, "Phone title")
            XCTAssertNotNil(sync.lastError)
            XCTAssertFalse(ledger.ledger.twoWayEnabled)
            self.edit(source, title: "Synthetic task")
            source.completeFirst()
            await sync.reconcileNow()
            XCTAssertTrue(try store.file.load().tasks[0].done)
            XCTAssertNil(sync.lastError)
        }
    }

    @MainActor
    func testConfirmedBringBackImportsAndSurvivesRestart() async throws {
        try await exercise { store, source, ledger, sync in
            sync.setTwoWayEnabled(true)
            XCTAssertEqual(try store.file.load().preferences.phoneEdits, .bringBack)
            self.edit(source, title: "Phone title")
            await sync.reconcileNow()
            XCTAssertEqual(try store.file.load().tasks[0].title, "Phone title")
            XCTAssertNil(sync.lastError)
            let restarted = RemindersSync(
                store: store, source: source, storage: ledger, scheduler: PhoneEditScheduler(), observing: false)
            XCTAssertTrue(restarted.twoWayEnabled)
            self.edit(source, title: "After restart")
            await restarted.reconcileNow()
            XCTAssertEqual(try store.file.load().tasks[0].title, "After restart")
            XCTAssertEqual(source.saves, 1)
        }
    }

    @MainActor
    func testExternalIgnoreStopsImportsEvenWithOldConsentAndBringBackResumes() async throws {
        try await exercise { store, source, ledger, sync in
            sync.setTwoWayEnabled(true)
            await sync.reconcileNow()
            let external = PlannerCommandPipeline(file: store.file)
            _ = try external.perform(origin: .background) { try $0.updatePreference(.phoneEdits(.ignore)) }
            store.reloadFromDisk(external: true)
            self.edit(source, title: "Phone title")
            await sync.reconcileNow()
            XCTAssertEqual(try store.file.load().tasks[0].title, "Synthetic task")
            XCTAssertFalse(sync.twoWayEnabled)
            let consent = await sync.refreshTwoWayConsent()
            XCTAssertEqual(consent, false)
            XCTAssertEqual(store.prefs.phoneEdits, .ignore)
            XCTAssertTrue(ledger.ledger.twoWayEnabled, "The document restricts rather than manufactures consent")
            _ = try external.perform(origin: .background) { try $0.updatePreference(.phoneEdits(.bringBack)) }
            store.reloadFromDisk(external: true)
            await sync.reconcileNow()
            XCTAssertEqual(try store.file.load().tasks[0].title, "Phone title")
            XCTAssertTrue(sync.twoWayEnabled)
        }
    }

    @MainActor
    func testIgnoreSelectedDuringFetchCancelsTwoWayImport() async throws {
        try await exercise { store, source, ledger, sync in
            sync.setTwoWayEnabled(true)
            await sync.reconcileNow()
            self.edit(source, title: "Phone title")
            source.onFetch = {
                source.onFetch = nil
                _ = store.performMutation(origin: .background) { try $0.updatePreference(.phoneEdits(.ignore)) }
            }
            await sync.reconcileNow()
            XCTAssertEqual(try store.file.load().tasks[0].title, "Synthetic task")
            XCTAssertEqual(source.records[0].fields.title, "Phone title")
            XCTAssertTrue(ledger.ledger.links.values.allSatisfy { $0.pending == nil })
            XCTAssertNotNil(sync.lastError)
        }
    }

    @MainActor
    func testStoredBringBackCannotGrantConsentOrImportADeletion() async throws {
        try await exercise { store, source, ledger, sync in
            XCTAssertNotNil(store.apply { try $0.updatePreference(.phoneEdits(.bringBack)) })
            self.edit(source, title: "Phone title")
            await sync.reconcileNow()
            XCTAssertFalse(ledger.ledger.twoWayEnabled)
            XCTAssertEqual(try store.file.load().tasks[0].title, "Synthetic task")
            source.records = []
            await sync.reconcileNow()
            XCTAssertEqual(try store.file.load().tasks.count, 1)
            XCTAssertNotNil(sync.lastError)
            let consent = await sync.refreshTwoWayConsent()
            XCTAssertEqual(consent, false)
        }
    }

    @MainActor
    func testUndoRestoringBringBackCannotResumeHistoryPausedSync() async throws {
        try await exercise { store, source, ledger, sync in
            sync.setTwoWayEnabled(true)
            await sync.reconcileNow()
            XCTAssertNotNil(store.apply { try $0.updatePreference(.phoneEdits(.ignore)) })
            store.undo()
            XCTAssertEqual(store.prefs.phoneEdits, .bringBack)
            self.edit(source, title: "Phone title")
            await sync.reconcileNow()
            XCTAssertFalse(ledger.ledger.enabled)
            XCTAssertEqual(try store.file.load().tasks[0].title, "Synthetic task")
            let consent = await sync.refreshTwoWayConsent()
            XCTAssertEqual(consent, true, "Reading mode consent does not resume the separate history pause")
            XCTAssertFalse(ledger.ledger.enabled)
            let restarted = RemindersSync(
                store: store, source: source, storage: ledger, scheduler: PhoneEditScheduler(), observing: false)
            await restarted.reconcileNow()
            XCTAssertEqual(try store.file.load().tasks[0].title, "Synthetic task")
            XCTAssertFalse(ledger.ledger.enabled)
        }
    }
}
