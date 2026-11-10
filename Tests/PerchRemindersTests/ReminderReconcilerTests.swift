import Foundation
import PlannerCore
import PerchReminders
import XCTest

@MainActor
private final class MemoryLedger: ReminderLedgerStorage {
    var value = ReminderLedger()
    var writes = 0
    var failWriteAt: Int?
    var locked = false
    func lock() throws {
        guard !locked else { throw ReminderSyncError.stopped("busy") }
        locked = true
    }
    func unlock() { locked = false }
    func load() throws -> ReminderLedger { value }
    func save(_ ledger: ReminderLedger) throws {
        writes += 1
        if failWriteAt == writes { throw ReminderSyncError.stopped("disk full") }
        value = ledger
    }
}

@MainActor
private final class FakeRepository: ReminderRepository {
    var hasAccess = true
    var records: [ReminderRecord] = []
    var saves = 0
    var removes = 0
    var lists = 0
    var fetches = 0
    var failSaveAt: Int?
    var throwAfterSave = false
    var onFetch: (() async throws -> Void)?
    var beforeWrite: (() -> Void)?
    func createCalendar() throws -> String { lists += 1; return "owned-list" }
    func fetch(calendarID: String) async throws -> [ReminderRecord] {
        fetches += 1
        try await onFetch?()
        return records
    }
    func save(fields: ReminderFields, owner: ReminderOwner, calendarID: String, replacing: ReminderRecord?) throws
        -> ReminderRecord
    {
        beforeWrite?()
        guard hasAccess else { throw ReminderSyncError.stopped("denied") }
        if let replacing, !records.contains(replacing) { throw ReminderSyncError.stopped("revision conflict") }
        saves += 1
        if failSaveAt == saves { throw ReminderSyncError.stopped("save failed") }
        let saved = ReminderRecord(
            id: replacing?.id ?? "r-\(saves)", calendarID: calendarID, owner: owner, fields: fields,
            revision: "rev-\(saves)")
        records.removeAll { $0.id == saved.id }; records.append(saved)
        if throwAfterSave { throw ReminderSyncError.stopped("uncertain commit") }
        return saved
    }
    func remove(_ expected: ReminderRecord) throws {
        beforeWrite?()
        guard hasAccess, records.contains(expected) else { throw ReminderSyncError.stopped("revision conflict") }
        removes += 1; records.removeAll { $0.id == expected.id }
    }
    func change(_ transform: (inout ReminderFields) -> Void) {
        let old = records[0]; var fields = old.fields; transform(&fields)
        records[0] = ReminderRecord(
            id: old.id, calendarID: old.calendarID, owner: old.owner, fields: fields, revision: "external")
    }
}

@MainActor
private final class Fixture {
    let storage = MemoryLedger()
    let repository = FakeRepository()
    let today: DayKey = "2026-06-10"
    var planner = Planner()
    var engine: ReminderReconciler { ReminderReconciler(repository: repository, storage: storage) }
    init() {
        storage.value.enabled = true
        planner.tasks = [PlanTask(title: "Synthetic task", day: today)]
    }
    func run() async throws { try await engine.reconcile(planner, today: today) }
}

final class ReminderReconcilerTests: XCTestCase {
    @MainActor func testNoOpMakesZeroRemoteAndLedgerWrites() async throws {
        let f = Fixture(); try await f.run()
        let saves = f.repository.saves, writes = f.storage.writes
        for _ in 0..<5 { try await f.run() }
        XCTAssertEqual(f.repository.saves, saves)
        XCTAssertEqual(f.repository.lists, 1); XCTAssertEqual(f.repository.removes, 0)
        XCTAssertEqual(f.storage.writes, writes)
    }

    @MainActor func testDefaultOffAndEmptyPlannerNeverTouchReminders() async throws {
        let f = Fixture(); f.storage.value.enabled = false
        do { try await f.run(); XCTFail("consent required") } catch {}
        XCTAssertEqual(f.repository.fetches, 0); XCTAssertEqual(f.repository.saves, 0)
        f.storage.value.enabled = true; f.planner.tasks = []
        try await f.run()
        XCTAssertEqual(f.repository.lists, 0)
        XCTAssertFalse(Preferences().remindersSync)
    }

    @MainActor func testLocalEditsReuseIdentityOutsidePlanner() async throws {
        let f = Fixture(); try await f.run()
        let owner = f.repository.records[0].owner, id = f.repository.records[0].id
        f.planner.tasks[0].title = "Changed title"; f.planner.tasks[0].notes = "Changed note"
        try await f.run()
        XCTAssertEqual(f.repository.records[0].owner, owner)
        XCTAssertEqual(f.repository.records[0].id, id)
        XCTAssertNil(f.planner.tasks[0].reminderLink)
        XCTAssertEqual(f.repository.saves, 2)
    }

    @MainActor func testDeleteAndUnscheduleRemoveOnlyOwnedRecords() async throws {
        for delete in [true, false] {
            let f = Fixture(); try await f.run()
            let other = ReminderRecord(
                id: "user", calendarID: "owned-list", owner: nil, fields: f.repository.records[0].fields,
                revision: "user")
            f.repository.records.append(other)
            if delete { f.planner.tasks = [] } else { f.planner.tasks[0].day = nil }
            try await f.run(); try await f.run()
            XCTAssertEqual(f.repository.records, [other]); XCTAssertEqual(f.repository.removes, 1)
        }
    }

    @MainActor func testCarryRetiresOriginalAndCreatesOneNewMirror() async throws {
        let f = Fixture(); try await f.run()
        let old = f.repository.records[0].owner
        var engine = PlannerEngine(planner: f.planner, now: { f.today.adding(days: 1).date() })
        _ = engine.carryForward([f.planner.tasks[0].id], to: f.today.adding(days: 1))
        f.planner = engine.planner
        try await f.engine.reconcile(f.planner, today: f.today.adding(days: 1))
        XCTAssertEqual(f.repository.removes, 1); XCTAssertEqual(f.repository.records.count, 1)
        XCTAssertNotEqual(f.repository.records[0].owner, old)
    }

    @MainActor func testCompletionFromTodayDoesNotWriteEventKit() async throws {
        let f = Fixture(); try await f.run(); f.repository.change { $0.completed = true }
        var completed: [UUID] = []
        try await f.engine.reconcile(
            f.planner, today: f.today,
            complete: { task in
                completed.append(task.id); f.planner.tasks[0].done = true
            })
        try await f.run()
        XCTAssertEqual(completed, [f.planner.tasks[0].id]); XCTAssertEqual(f.repository.saves, 1)
    }

    @MainActor func testConcurrentRemoteTextAndLocalEditStopWithoutOverwrite() async throws {
        let f = Fixture(); try await f.run()
        f.repository.change { $0.title = "Remote edit" }; f.planner.tasks[0].notes = "Local edit"
        do { try await f.run(); XCTFail("must conflict") } catch {}
        XCTAssertEqual(f.repository.saves, 1); XCTAssertEqual(f.repository.records[0].fields.title, "Remote edit")
    }

    @MainActor func testRemoteDeleteReopenAndFutureCompletionAreNotInventedImports() async throws {
        for mode in 0..<3 {
            let f = Fixture()
            if mode == 2 { f.planner.tasks[0].day = f.today.adding(days: 1) }
            try await f.run()
            if mode == 0 { f.repository.records = [] }
            if mode == 1 {
                f.planner.tasks[0].done = true; try await f.run()
                f.repository.change { $0.completed = false }
            }
            if mode == 2 { f.repository.change { $0.completed = true } }
            let saves = f.repository.saves
            do { try await f.run(); XCTFail("must stop") } catch {}
            XCTAssertEqual(f.repository.saves, saves)
        }
    }

    @MainActor func testConcurrentChangeAtWriteUsesExpectedRevision() async throws {
        let f = Fixture(); try await f.run(); f.planner.tasks[0].title = "Local edit"
        f.repository.beforeWrite = { f.repository.change { $0.notes = "Concurrent remote note" } }
        do { try await f.run(); XCTFail("revision conflict expected") } catch {}
        XCTAssertEqual(f.repository.saves, 1)
        XCTAssertEqual(f.repository.records[0].fields.notes, "Concurrent remote note")
    }

    @MainActor func testRevocationBeforeFetchAndBeforeWriteStops() async throws {
        let f = Fixture(); f.repository.hasAccess = false
        do { try await f.run(); XCTFail("denied") } catch {}
        XCTAssertEqual(f.repository.lists, 0)
        f.repository.hasAccess = true; try await f.run()
        f.planner.tasks[0].title = "Local edit"
        f.repository.onFetch = { f.repository.hasAccess = false }
        do { try await f.run(); XCTFail("revoked") } catch {}
        XCTAssertEqual(f.repository.saves, 1)
    }

    @MainActor func testPartialPassRetriesOnlyUncommittedRecord() async throws {
        let f = Fixture(); f.planner.tasks.append(PlanTask(title: "Second", day: f.today))
        f.repository.failSaveAt = 2
        do { try await f.run(); XCTFail("partial failure") } catch {}
        XCTAssertEqual(f.repository.records.count, 1)
        f.repository.failSaveAt = nil; try await f.run(); try await f.run()
        XCTAssertEqual(f.repository.records.count, 2); XCTAssertEqual(f.repository.saves, 3)
    }

    @MainActor func testUncertainCommitAndRestartRecoverByPersistedOwner() async throws {
        let f = Fixture(); f.repository.throwAfterSave = true
        do { try await f.run(); XCTFail("uncertain commit") } catch {}
        let owner = f.repository.records[0].owner
        XCTAssertNil(f.storage.value.links[f.planner.tasks[0].id]?.remoteID)
        f.repository.throwAfterSave = false
        try await f.run(); try await f.run()
        XCTAssertEqual(f.repository.saves, 1); XCTAssertEqual(f.repository.records[0].owner, owner)
    }

    @MainActor func testLedgerFailureAfterRemoteCommitDoesNotDuplicateOnRestart() async throws {
        let f = Fixture(); f.storage.failWriteAt = 3
        do { try await f.run(); XCTFail("disk failure") } catch {}
        XCTAssertEqual(f.repository.records.count, 1)
        f.storage.failWriteAt = nil; try await f.run()
        XCTAssertEqual(f.repository.records.count, 1); XCTAssertEqual(f.repository.saves, 1)
    }

    @MainActor func testPendingIntentFailurePreventsRemoteWrite() async throws {
        let f = Fixture(); f.storage.failWriteAt = 2
        do { try await f.run(); XCTFail("disk failure") } catch {}
        XCTAssertEqual(f.repository.saves, 0)
    }

    @MainActor func testMissingOwnershipAndEditedDeletedRecordArePreserved() async throws {
        for removeMarker in [true, false] {
            let f = Fixture(); try await f.run()
            let r = f.repository.records[0]
            if removeMarker {
                f.repository.records[0] = ReminderRecord(
                    id: r.id, calendarID: r.calendarID, owner: nil, fields: r.fields, revision: "changed")
            } else {
                f.repository.change { $0.notes = "Remote note" }
            }
            f.planner.tasks = []
            do { try await f.run(); XCTFail("preserve unexpected record") } catch {}
            XCTAssertEqual(f.repository.removes, 0); XCTAssertEqual(f.repository.records.count, 1)
        }
    }

    @MainActor func testDuplicateOwnershipFailsClosed() async throws {
        let f = Fixture(); try await f.run(); let r = f.repository.records[0]
        f.repository.records.append(
            ReminderRecord(
                id: "duplicate", calendarID: r.calendarID, owner: r.owner, fields: r.fields, revision: "duplicate"))
        do { try await f.run(); XCTFail("duplicate ownership") } catch {}
        XCTAssertEqual(f.repository.saves, 1)
    }

    @MainActor func testReentrantRunIsRejectedAndNextRunWorks() async throws {
        let f = Fixture(); let engine = f.engine
        var rejected = false
        f.repository.onFetch = {
            do { try await engine.reconcile(f.planner, today: f.today) } catch { rejected = true }
        }
        try await engine.reconcile(f.planner, today: f.today)
        f.repository.onFetch = nil; try await engine.reconcile(f.planner, today: f.today)
        XCTAssertTrue(rejected); XCTAssertEqual(f.repository.saves, 1)
    }

    @MainActor func testLocalGenerationChangeDuringFetchPreventsWrite() async throws {
        let f = Fixture(); var changed = false
        f.repository.onFetch = { changed = true }
        do {
            try await f.engine.reconcile(
                f.planner, today: f.today,
                validate: {
                    if changed { throw ReminderSyncError.stopped("stale local revision") }
                })
            XCTFail("must reject stale snapshot")
        } catch {}
        XCTAssertEqual(f.repository.saves, 0)
    }

    @MainActor func testDurableLedgerRoundTripLockAndCorruptionFailClosed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("reminders.json")
        let first = ReminderLedgerFile(url: url), second = ReminderLedgerFile(url: url)
        try first.lock(); var value = try first.load(); value.enabled = true
        let task = UUID();
        value.links[task] = ReminderLink(owner: ReminderOwner(installation: value.installation, task: task))
        try first.save(value)
        XCTAssertThrowsError(try second.lock())
        first.unlock(); try second.lock()
        XCTAssertEqual(try second.load(), value); second.unlock()
        try Data("invalid".utf8).write(to: url)
        try first.lock(); XCTAssertThrowsError(try first.load()); first.unlock()
        XCTAssertEqual(try Data(contentsOf: url), Data("invalid".utf8))
    }
}
