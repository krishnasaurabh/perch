import Foundation
import PerchReminders
import PlannerCore
import XCTest

@MainActor
private final class TwoWayLedger: ReminderLedgerStorage {
    var value = ReminderSyncLedger()
    var locked = false
    var writes = 0
    var failAt: Int?
    func lock() throws {
        guard !locked else { throw ReminderSyncError.stopped("locked") }
        locked = true
    }
    func unlock() { locked = false }
    func load() throws -> ReminderSyncLedger { value }
    func save(_ value: ReminderSyncLedger) throws {
        writes += 1
        if writes == failAt { throw ReminderSyncError.stopped("storage failure") }
        self.value = value
    }
}

@MainActor
private final class TwoWayRepository: ReminderRepository {
    var hasAccess = true
    var records: [ReminderSyncRecord] = []
    var saves = 0
    var removals = 0
    var ownerLookups = 0
    var failSave = false
    var uncertainSave = false
    var uncertainDelete = false
    var beforeWrite: (() -> Void)?
    var onLookup: (() -> Void)?
    var onFetch: (() async -> Void)?
    var onLocate: (() async -> Void)?
    func createCalendar() throws -> String { "synthetic-list" }
    func fetch(calendarID: String) async throws -> [ReminderSyncRecord] {
        await onFetch?()
        return records.filter { $0.calendarID == calendarID }
    }
    func locate(owner: ReminderOwner) async throws -> [ReminderSyncRecord] {
        ownerLookups += 1
        await onLocate?()
        guard hasAccess else { throw ReminderSyncError.stopped("permission denied") }
        return records.filter { $0.owner == owner }
    }
    func lookup(id: String) throws -> ReminderSyncRecord? {
        onLookup?()
        guard hasAccess else { throw ReminderSyncError.stopped("permission denied") }
        return records.first { $0.id == id }
    }
    func save(fields: ReminderFields, owner: ReminderOwner, calendarID: String, replacing: ReminderSyncRecord?) throws
        -> ReminderSyncRecord
    {
        beforeWrite?()
        guard hasAccess, !failSave else { throw ReminderSyncError.stopped("write failure") }
        if let replacing, !records.contains(replacing) { throw ReminderSyncError.stopped("revision changed") }
        saves += 1
        let record = ReminderSyncRecord(
            id: replacing?.id ?? "synthetic-\(saves)", calendarID: calendarID, owner: owner, fields: fields,
            revision: "write-\(saves)")
        records.removeAll { $0.id == record.id }; records.append(record)
        if uncertainSave { throw ReminderSyncError.stopped("uncertain save") }
        return record
    }
    func remove(_ expected: ReminderSyncRecord) throws {
        beforeWrite?()
        guard hasAccess, records.contains(expected) else { throw ReminderSyncError.stopped("revision changed") }
        records.removeAll { $0.id == expected.id }; removals += 1
        if uncertainDelete { throw ReminderSyncError.stopped("uncertain deletion") }
    }
    func edit(_ change: (inout ReminderFields) -> Void) {
        let old = records[0]; var fields = old.fields; change(&fields)
        records[0] = ReminderSyncRecord(
            id: old.id, calendarID: old.calendarID, owner: old.owner, fields: fields, revision: old.revision + "-edit")
    }
}

@MainActor
private final class TwoWayFixture {
    let ledger = TwoWayLedger()
    let remote = TwoWayRepository()
    var planner = Planner()
    let today: DayKey = "2026-06-10"
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }
    var now: Date { today.date(calendar: calendar).addingTimeInterval(36_000) }
    var applied = 0
    var failLocal = false
    var failAfterLocal = false
    var invalidated = false
    init() {
        planner.preferences.resetHour = 0
        planner.tasks = [PlanTask(title: "Synthetic task", day: today, createdAt: now)]
        ledger.value.enabled = true; ledger.value.twoWayEnabled = true
    }
    var engine: ReminderReconciler { ReminderReconciler(repository: remote, storage: ledger) }
    func run() async throws {
        try await engine.reconcile(
            planner, today: today,
            validate: {
                if self.invalidated { throw ReminderSyncError.stopped("local revision changed") }
            },
            prepareImport: { task, fields in
                _ = try ReminderTaskImport.actions(
                    task: task, fields: fields, planner: self.planner, now: self.now, calendar: self.calendar)
            },
            applyImport: { task, fields in
                if self.failLocal { throw ReminderSyncError.stopped("local save failure") }
                XCTAssertEqual(self.planner.tasks.first { $0.id == task.id }, task)
                let actions = try ReminderTaskImport.actions(
                    task: task, fields: fields, planner: self.planner, now: self.now, calendar: self.calendar)
                var commands = PlannerEngine(planner: self.planner, now: { self.now }, calendar: self.calendar)
                for action in actions { try commands.execute(action) }
                self.planner = commands.planner; self.applied += 1
                if self.failAfterLocal { throw ReminderSyncError.stopped("uncertain local commit") }
            })
    }
    func expectStop(file: StaticString = #filePath, line: UInt = #line) async {
        do { try await run(); XCTFail("sync must stop", file: file, line: line) } catch {}
    }
}

final class TwoWayReminderTests: XCTestCase {
    @MainActor func testOneWayInboxRoundTripPreservesIdentity() async throws {
        let f = TwoWayFixture(); f.ledger.value.twoWayEnabled = false
        try await f.run()
        let task = f.planner.tasks[0], owner = f.remote.records[0].owner
        var commands = PlannerEngine(planner: f.planner, now: { f.now }, calendar: f.calendar)
        try commands.execute(.move(task.id, .inbox)); f.planner = commands.planner
        XCTAssertNil(f.planner.tasks[0].day)
        try await f.run(); XCTAssertTrue(f.remote.records.isEmpty)
        try commands.execute(.move(task.id, .day(f.today))); f.planner = commands.planner
        XCTAssertEqual(f.planner.tasks[0].day, f.today)
        try await f.run(); try await f.run()
        XCTAssertEqual(f.remote.records.count, 1)
        XCTAssertEqual(f.remote.records[0].owner, owner)
        XCTAssertEqual(f.remote.saves, 2); XCTAssertEqual(f.remote.removals, 1)
    }

    @MainActor func testEnableTwoWayAfterOneWayRolloverKeepsHistory() async throws {
        let f = TwoWayFixture(); f.ledger.value.twoWayEnabled = false
        try await f.run()
        let task = f.planner.tasks[0]
        try await f.engine.reconcile(f.planner, today: f.today.adding(days: 1))
        XCTAssertTrue(f.remote.records.isEmpty)
        try f.engine.setTwoWayEnabled(true)
        try await f.engine.reconcile(f.planner, today: f.today.adding(days: 1))
        XCTAssertEqual(f.planner.tasks, [task]); XCTAssertEqual(f.remote.saves, 1)
        XCTAssertEqual(f.remote.removals, 1)
        // Rescheduling the same live task brings it back into the mirrored scope.
        f.planner.tasks[0].day = f.today.adding(days: 1)
        try await f.engine.reconcile(f.planner, today: f.today.adding(days: 1))
        XCTAssertEqual(f.remote.records.count, 1); XCTAssertEqual(f.remote.saves, 2)
    }

    @MainActor func testUncertainCreateMovedBeforeRestartDoesNotDuplicate() async throws {
        for twoWay in [false, true] {
            for refreshedID in [false, true] {
                let f = TwoWayFixture(); f.ledger.value.twoWayEnabled = twoWay
                f.remote.uncertainSave = true; await f.expectStop()
                let old = try XCTUnwrap(f.remote.records.first)
                XCTAssertNil(f.ledger.value.links[f.planner.tasks[0].id]?.remoteID)
                let moved = ReminderSyncRecord(
                    id: refreshedID ? "refreshed-id" : old.id, calendarID: "other-list",
                    owner: old.owner, fields: old.fields, revision: "moved")
                f.remote.records = [moved]; f.remote.uncertainSave = false
                let ledger = f.ledger.value
                await f.expectStop(); await f.expectStop()
                XCTAssertEqual(f.remote.records, [moved]); XCTAssertEqual(f.remote.saves, 1)
                XCTAssertEqual(f.remote.removals, 0); XCTAssertEqual(f.applied, 0)
                XCTAssertEqual(f.ledger.value, ledger); XCTAssertGreaterThanOrEqual(f.remote.ownerLookups, 2)
                // Returning the committed copy to the selected list recovers the original intent.
                f.remote.records = [old]
                try await f.run(); XCTAssertEqual(f.remote.saves, 1)
            }
        }
    }

    @MainActor func testScopeExitMetadataSurvivesRestartAndModeChange() async throws {
        for twoWay in [false, true] {
            let f = TwoWayFixture(); f.ledger.value.twoWayEnabled = false
            try await f.run(); let task = f.planner.tasks[0]
            f.planner.tasks[0].day = nil; try await f.run()
            let link = try XCTUnwrap(f.ledger.value.links[task.id])
            XCTAssertEqual(link.retirement, .outOfScope); XCTAssertNil(link.deletedAt)
            f.ledger.value = try JSONDecoder().decode(
                ReminderSyncLedger.self, from: JSONEncoder().encode(f.ledger.value))
            try f.engine.setTwoWayEnabled(twoWay); try await f.run()
            XCTAssertEqual(f.planner.tasks.count, 1); XCTAssertTrue(f.remote.records.isEmpty)
            f.planner.tasks[0].day = f.today; try await f.run(); try await f.run()
            XCTAssertEqual(f.remote.saves, 2); XCTAssertEqual(f.remote.records.count, 1)
            XCTAssertEqual(f.remote.records[0].owner, link.owner)
            XCTAssertFalse(f.ledger.value.links[task.id]!.retired)
            XCTAssertNil(f.ledger.value.links[task.id]!.retirement)
        }
    }

    @MainActor func testDeletionWhileSuspendedNeverAllowsIdentityReuse() async throws {
        for twoWay in [false, true] {
            let f = TwoWayFixture(); f.ledger.value.twoWayEnabled = false
            try await f.run(); let task = f.planner.tasks[0]
            f.planner.tasks[0].day = nil; try await f.run()
            try f.engine.setTwoWayEnabled(twoWay)
            f.planner.tasks = []; try await f.run()
            let link = try XCTUnwrap(f.ledger.value.links[task.id])
            XCTAssertEqual(link.retirement, .deleted); XCTAssertNotNil(link.deletedAt)
            f.ledger.value = try JSONDecoder().decode(
                ReminderSyncLedger.self, from: JSONEncoder().encode(f.ledger.value))
            f.planner.tasks = [task]; await f.expectStop()
            XCTAssertTrue(f.remote.records.isEmpty); XCTAssertEqual(f.remote.saves, 1)
        }
    }

    @MainActor func testScopeExitDoesNotForgetMissingOrReappearedReminder() async throws {
        let f = TwoWayFixture(); f.ledger.value.twoWayEnabled = false
        try await f.run(); let old = f.remote.records[0]
        f.remote.records = []; f.planner.tasks[0].day = nil
        await f.expectStop()
        XCTAssertFalse(f.ledger.value.links[f.planner.tasks[0].id]!.retired)
        f.remote.records = [old]; try await f.run()
        f.remote.records = [old]
        f.planner.tasks[0].day = f.today
        await f.expectStop(); XCTAssertEqual(f.remote.records, [old])
        try f.engine.setTwoWayEnabled(true)
        await f.expectStop(); XCTAssertEqual(f.remote.records, [old])
        XCTAssertEqual(f.remote.saves, 1); XCTAssertEqual(f.remote.removals, 1)
    }

    @MainActor func testOldRetiredMetadataPreservesHistoryButCannotResumeUnknownIdentity() async throws {
        for version in [1, 2] {
            let f = TwoWayFixture(); f.ledger.value.twoWayEnabled = false
            try await f.run(); let id = f.planner.tasks[0].id
            f.planner.tasks[0].day = f.today.adding(days: -1); try await f.run()
            let bytes = try JSONEncoder().encode(f.ledger.value)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            object["version"] = version
            f.ledger.value = try JSONDecoder().decode(
                ReminderSyncLedger.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertNil(f.ledger.value.links[id]!.retirement)
            try f.engine.setTwoWayEnabled(true)
            f.planner.tasks.append(PlanTask(title: "Another synthetic task", day: f.today, createdAt: f.now))
            try await f.run()
            XCTAssertEqual(f.planner.tasks.count, 2); XCTAssertEqual(f.remote.records.count, 1)
            f.planner.tasks[0].day = f.today
            await f.expectStop(); XCTAssertEqual(f.remote.records.count, 1)
            XCTAssertEqual(f.remote.saves, 2)
            XCTAssertTrue(f.ledger.value.links[id]!.retired)
        }
    }

    @MainActor func testUncertainCreateAmbiguousOwnerOrRevocationPreservesIntent() async throws {
        for twoWay in [false, true] {
            for revoked in [false, true] {
                let f = TwoWayFixture(); f.ledger.value.twoWayEnabled = twoWay
                f.remote.uncertainSave = true; await f.expectStop()
                let old = try XCTUnwrap(f.remote.records.first)
                f.remote.records = ["first", "second"].map {
                    ReminderSyncRecord(
                        id: $0, calendarID: "other-list", owner: old.owner,
                        fields: old.fields, revision: "moved")
                }
                f.remote.uncertainSave = false
                if revoked { f.remote.onLocate = { f.remote.hasAccess = false } }
                let records = f.remote.records, ledger = f.ledger.value
                await f.expectStop()
                XCTAssertEqual(f.remote.records, records); XCTAssertEqual(f.ledger.value, ledger)
                XCTAssertEqual(f.remote.saves, 1); XCTAssertEqual(f.remote.removals, 0)
                XCTAssertEqual(f.applied, 0); XCTAssertEqual(f.remote.ownerLookups, 1)
            }
        }
    }

    @MainActor func testInvalidScopeRetirementCannotDecodeAsPermissionToResume() async throws {
        let f = TwoWayFixture(); f.ledger.value.twoWayEnabled = false
        try await f.run(); f.planner.tasks[0].day = nil; try await f.run()
        let id = f.planner.tasks[0].id
        f.ledger.value.links[id]!.deletedAt = f.now
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ReminderSyncLedger.self, from: JSONEncoder().encode(f.ledger.value)))
        f.ledger.value.links[id]!.deletedAt = nil
        f.ledger.value.links[id]!.retired = false
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ReminderSyncLedger.self, from: JSONEncoder().encode(f.ledger.value)))
    }

    @MainActor func testRemoteFieldsImportAndNoOp() async throws {
        let f = TwoWayFixture(); try await f.run()
        f.remote.edit {
            $0.title = "Remote title"; $0.notes = "Remote note"; $0.priority = 1
        }
        try await f.run()
        XCTAssertEqual(f.planner.tasks[0].title, "Remote title")
        XCTAssertEqual(f.planner.tasks[0].notes, "Remote note")
        XCTAssertEqual(f.planner.tasks[0].priority, .high)
        let writes = f.ledger.writes
        try await f.run()
        XCTAssertEqual(f.applied, 1); XCTAssertEqual(f.remote.saves, 1); XCTAssertEqual(f.ledger.writes, writes)
    }
    @MainActor func testRemoteCompletionAndReopenToday() async throws {
        let f = TwoWayFixture(); try await f.run()
        f.remote.edit { $0.completed = true }; try await f.run()
        XCTAssertTrue(f.planner.tasks[0].done)
        f.remote.edit { $0.completed = false }; try await f.run()
        XCTAssertFalse(f.planner.tasks[0].done); XCTAssertNil(f.planner.tasks[0].completedAt)
        XCTAssertEqual(f.remote.saves, 1)
    }
    @MainActor func testLocalCompletionAndReopenExport() async throws {
        let f = TwoWayFixture(); try await f.run()
        f.planner.tasks[0].done = true; try await f.run(); XCTAssertTrue(f.remote.records[0].fields.completed)
        f.planner.tasks[0].done = false; try await f.run(); XCTAssertFalse(f.remote.records[0].fields.completed)
        XCTAssertEqual(f.remote.saves, 3)
    }
    @MainActor func testDisjointEditsMergeWithoutClockWinner() async throws {
        let f = TwoWayFixture(); try await f.run()
        f.planner.tasks[0].notes = "Local note"
        f.remote.edit { $0.title = "Remote title" }
        try await f.run()
        XCTAssertEqual(f.planner.tasks[0].title, "Remote title")
        XCTAssertEqual(f.planner.tasks[0].notes, "Local note")
        XCTAssertEqual(f.remote.records[0].fields.notes, "Local note")
        XCTAssertEqual(f.remote.records[0].fields.title, "Remote title")
    }
    @MainActor func testSameFieldConflictPreservesBoth() async throws {
        let f = TwoWayFixture(); try await f.run()
        f.planner.tasks[0].title = "Local"; f.remote.edit { $0.title = "Remote" }
        let writes = f.ledger.writes
        await f.expectStop()
        XCTAssertEqual(f.planner.tasks[0].title, "Local"); XCTAssertEqual(f.remote.records[0].fields.title, "Remote")
        XCTAssertEqual(f.ledger.writes, writes); XCTAssertEqual(f.remote.saves, 1)
        f.planner.tasks[0].title = "Remote"; try await f.run()
        XCTAssertEqual(f.remote.saves, 1)
    }
    @MainActor func testRemoteDateMoveClearAndLocalDateExport() async throws {
        let f = TwoWayFixture(); try await f.run()
        f.remote.edit {
            $0.due = f.calendar.dateComponents(
                [.year, .month, .day], from: f.today.adding(days: 2).date(calendar: f.calendar))
        }
        try await f.run(); XCTAssertEqual(f.planner.tasks[0].day, f.today.adding(days: 2))
        f.planner.tasks[0].day = f.today.adding(days: 3); try await f.run()
        XCTAssertEqual(f.remote.records[0].fields.due?.day, 13)
        f.remote.edit { $0.due = nil }; try await f.run()
        XCTAssertNil(f.planner.tasks[0].day); XCTAssertNil(f.planner.tasks[0].remindAt)
        try await f.run(); XCTAssertEqual(f.remote.records.count, 1)
    }
    @MainActor func testRemoteTimedDateAndAlarmImport() async throws {
        let f = TwoWayFixture(); f.planner.preferences.ringOnPhone = true; try await f.run()
        let at = f.now.addingTimeInterval(3_600)
        f.remote.edit {
            $0.due = f.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: at)
            $0.due?.timeZone = f.calendar.timeZone; $0.alarm = at
        }
        try await f.run(); XCTAssertEqual(f.planner.tasks[0].remindAt, at)
        XCTAssertEqual(f.remote.saves, 1)
    }
    @MainActor func testFutureCompletionStopsWithoutChangingDates() async throws {
        let f = TwoWayFixture(); f.planner.tasks[0].day = f.today.adding(days: 1); try await f.run()
        f.remote.edit { $0.completed = true }; await f.expectStop()
        XCTAssertFalse(f.planner.tasks[0].done); XCTAssertEqual(f.planner.tasks[0].day, f.today.adding(days: 1))
        XCTAssertNil(f.ledger.value.links[f.planner.tasks[0].id]?.pending)
    }
    @MainActor func testRemoteDeleteImportsAndLeavesTombstone() async throws {
        let f = TwoWayFixture(); try await f.run(); let old = f.planner.tasks[0]
        f.remote.records = []; try await f.run(); try await f.run()
        XCTAssertTrue(f.planner.tasks.isEmpty); XCTAssertEqual(f.applied, 1)
        XCTAssertTrue(f.ledger.value.links[old.id]!.retired)
        XCTAssertNotNil(f.ledger.value.links[old.id]!.deletedAt)
        f.planner.tasks = [old]; await f.expectStop(); XCTAssertEqual(f.remote.saves, 1)
    }
    @MainActor func testLocalDeleteNeverTouchesUnrelatedReminder() async throws {
        let f = TwoWayFixture(); try await f.run()
        let owned = f.remote.records[0]
        let other = ReminderSyncRecord(
            id: "unrelated", calendarID: owned.calendarID, owner: nil, fields: owned.fields, revision: "user")
        f.remote.records.append(other); f.planner.tasks = []
        try await f.run(); try await f.run()
        XCTAssertEqual(f.remote.records, [other]); XCTAssertEqual(f.remote.removals, 1)
    }
    @MainActor func testDeleteVersusEditConflictInBothDirections() async throws {
        for localDelete in [true, false] {
            let f = TwoWayFixture(); try await f.run()
            if localDelete {
                f.planner.tasks = []; f.remote.edit { $0.notes = "Remote edit" }
            } else {
                f.planner.tasks[0].notes = "Local edit"; f.remote.records = []
            }
            await f.expectStop(); XCTAssertEqual(f.remote.removals, 0); XCTAssertEqual(f.applied, 0)
        }
    }
    @MainActor func testMovedReminderIsNotMistakenForDeletion() async throws {
        let f = TwoWayFixture(); try await f.run(); let old = f.remote.records[0]
        f.remote.records[0] = ReminderSyncRecord(
            id: old.id, calendarID: "other-list", owner: old.owner, fields: old.fields, revision: "moved")
        await f.expectStop(); XCTAssertEqual(f.planner.tasks.count, 1); XCTAssertEqual(f.applied, 0)
    }
    @MainActor func testMovedReminderWithRefreshedIDIsNotDeleted() async throws {
        let f = TwoWayFixture(); try await f.run(); let old = f.remote.records[0]
        f.remote.records[0] = ReminderSyncRecord(
            id: "new-id", calendarID: "other-list", owner: old.owner, fields: old.fields, revision: "moved")
        await f.expectStop()
        XCTAssertEqual(f.planner.tasks.count, 1); XCTAssertEqual(f.applied, 0)
        XCTAssertEqual(f.remote.removals, 0)
    }

    @MainActor func testStableOwnerRecoversChangedIdentifier() async throws {
        let f = TwoWayFixture(); try await f.run(); let old = f.remote.records[0]
        f.remote.records[0] = ReminderSyncRecord(
            id: "refreshed-id", calendarID: old.calendarID, owner: old.owner, fields: old.fields, revision: "refresh")
        try await f.run(); XCTAssertEqual(f.remote.saves, 1)
        XCTAssertEqual(f.ledger.value.links[f.planner.tasks[0].id]?.remoteID, "refreshed-id")
    }
    @MainActor func testPendingIntentFailurePreventsAnyMutation() async throws {
        let f = TwoWayFixture(); try await f.run(); f.remote.edit { $0.title = "Remote" }
        f.ledger.failAt = f.ledger.writes + 1; await f.expectStop()
        XCTAssertEqual(f.applied, 0); XCTAssertEqual(f.planner.tasks[0].title, "Synthetic task")
    }
    @MainActor func testFailedLocalCommitRetriedAfterRestart() async throws {
        let f = TwoWayFixture(); try await f.run(); f.remote.edit { $0.notes = "Remote" }
        f.failLocal = true; await f.expectStop(); f.failLocal = false
        try await f.run(); try await f.run()
        XCTAssertEqual(f.applied, 1); XCTAssertEqual(f.remote.saves, 1);
        XCTAssertEqual(f.planner.tasks[0].notes, "Remote")
    }
    @MainActor func testUncertainLocalCommitAndCheckpointFailureDoNotReapply() async throws {
        for afterLocal in [true, false] {
            let f = TwoWayFixture(); try await f.run(); f.remote.edit { $0.title = "Remote" }
            if afterLocal { f.failAfterLocal = true } else { f.ledger.failAt = f.ledger.writes + 2 }
            await f.expectStop(); XCTAssertEqual(f.applied, 1)
            f.failAfterLocal = false; f.ledger.failAt = nil
            try await f.run(); try await f.run(); XCTAssertEqual(f.applied, 1)
        }
    }
    @MainActor func testUncertainCreateAndUpdateDoNotDuplicate() async throws {
        for update in [true, false] {
            let f = TwoWayFixture()
            if update { try await f.run(); f.planner.tasks[0].notes = "Local" }
            f.remote.uncertainSave = true; await f.expectStop()
            let saves = f.remote.saves
            f.remote.uncertainSave = false; try await f.run(); try await f.run()
            XCTAssertEqual(f.remote.records.count, 1); XCTAssertEqual(f.remote.saves, saves)
            XCTAssertNil(f.ledger.value.links[f.planner.tasks[0].id]?.pending)
        }
    }
    @MainActor func testUncertainDeleteDoesNotResurrect() async throws {
        let f = TwoWayFixture(); try await f.run(); f.planner.tasks = []
        f.remote.uncertainDelete = true; await f.expectStop(); f.remote.uncertainDelete = false
        try await f.run(); try await f.run()
        XCTAssertTrue(f.remote.records.isEmpty); XCTAssertEqual(f.remote.removals, 1)
    }
    @MainActor func testPartialMergedCommitRecoversWithoutLosingLocalEdit() async throws {
        let f = TwoWayFixture(); try await f.run()
        f.planner.tasks[0].notes = "Local"; f.remote.edit { $0.title = "Remote" }; f.remote.failSave = true
        await f.expectStop(); XCTAssertEqual(f.applied, 1)
        f.remote.failSave = false; try await f.run()
        XCTAssertEqual(f.remote.records[0].fields.notes, "Local"); XCTAssertEqual(f.planner.tasks[0].title, "Remote")
    }
    @MainActor func testPendingRecoveryDoesNotOverwriteAnotherEdit() async throws {
        let f = TwoWayFixture(); try await f.run(); f.planner.tasks[0].notes = "Local"
        f.remote.failSave = true; await f.expectStop(); f.remote.failSave = false
        f.remote.edit { $0.title = "Another edit" }; await f.expectStop()
        XCTAssertEqual(f.remote.saves, 1); XCTAssertEqual(f.remote.records[0].fields.title, "Another edit")
    }
    @MainActor func testConcurrentRemoteChangeBeforeSaveIsRejected() async throws {
        let f = TwoWayFixture(); try await f.run(); f.planner.tasks[0].notes = "Local"
        f.remote.beforeWrite = { f.remote.edit { $0.title = "Concurrent" } }
        await f.expectStop(); XCTAssertEqual(f.remote.saves, 1)
    }
    @MainActor func testConcurrentRemoteChangeBeforeImportIsRejected() async throws {
        let f = TwoWayFixture(); try await f.run(); f.remote.edit { $0.title = "First" }
        f.remote.onLookup = { f.remote.edit { $0.title = "Second" } }
        await f.expectStop(); XCTAssertEqual(f.applied, 0)
    }
    @MainActor func testLocalGenerationChangeDuringFetchIsRejected() async throws {
        let f = TwoWayFixture(); f.remote.onFetch = { f.invalidated = true }
        await f.expectStop(); XCTAssertEqual(f.remote.saves, 0)
    }
    @MainActor func testRevocationBeforeFetchAndDuringLookupOrSaveStops() async throws {
        for phase in 0..<3 {
            let f = TwoWayFixture(); try await f.run()
            if phase == 0 {
                f.remote.hasAccess = false
            } else if phase == 1 {
                f.remote.edit { $0.title = "Remote" }; f.remote.onLookup = { f.remote.hasAccess = false }
            } else {
                f.planner.tasks[0].notes = "Local"; f.remote.beforeWrite = { f.remote.hasAccess = false }
            }
            await f.expectStop(); XCTAssertEqual(f.applied, 0); XCTAssertEqual(f.remote.saves, 1)
        }
    }
    @MainActor func testReentrancyRejectedWithSharedLedger() async throws {
        let f = TwoWayFixture(); var rejected = false
        f.remote.onFetch = {
            do { try await f.run() } catch { rejected = true }
        }
        try await f.run(); XCTAssertTrue(rejected); XCTAssertEqual(f.remote.saves, 1)
    }
    @MainActor func testCannotLeaveTwoWayModeDuringPendingRecovery() async throws {
        let f = TwoWayFixture(); f.remote.failSave = true; await f.expectStop()
        XCTAssertThrowsError(try f.engine.setTwoWayEnabled(false))
        XCTAssertTrue(f.ledger.value.twoWayEnabled)
    }
    @MainActor func testUnsupportedFieldsAndDuplicateOwnerStop() async throws {
        for unsupported in [true, false] {
            let f = TwoWayFixture(); try await f.run(); let r = f.remote.records[0]
            let extra = ReminderSyncRecord(
                id: unsupported ? r.id : "duplicate", calendarID: r.calendarID, owner: r.owner, fields: r.fields,
                revision: "other", unsupported: unsupported)
            if unsupported { f.remote.records = [extra] } else { f.remote.records.append(extra) }
            await f.expectStop(); XCTAssertEqual(f.remote.saves, 1); XCTAssertEqual(f.applied, 0)
        }
    }
    @MainActor func testLegacyLedgerMigratesWithoutConsentAndKeepsTombstones() throws {
        let f = TwoWayFixture(); let id = f.planner.tasks[0].id
        var link = ReminderSyncLink(owner: ReminderOwner(installation: f.ledger.value.installation, task: id));
        link.retired = true
        f.ledger.value.links[id] = link
        let encoded = try JSONEncoder().encode(f.ledger.value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["version"] = 1; object.removeValue(forKey: "twoWayEnabled")
        let migrated = try JSONDecoder().decode(
            ReminderSyncLedger.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(migrated.version, 4); XCTAssertFalse(migrated.twoWayEnabled)
        XCTAssertTrue(migrated.links[id]!.retired); XCTAssertEqual(migrated.installation, f.ledger.value.installation)
    }
    @MainActor func testDurableIntentSurvivesEncodeLoadAndRestart() async throws {
        let f = TwoWayFixture(); try await f.run()
        f.planner.tasks[0].notes = "Local"; f.remote.edit { $0.title = "Remote" }
        f.remote.failSave = true; await f.expectStop()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = ReminderLedgerFile(url: root.appendingPathComponent("sync.json"))
        try file.lock(); try file.save(f.ledger.value); file.unlock()
        try file.lock(); let restored = try file.load(); file.unlock()
        XCTAssertEqual(restored, f.ledger.value)
        XCTAssertNotNil(restored.links[f.planner.tasks[0].id]?.pending)
        f.ledger.value = restored; f.remote.failSave = false
        try await f.run(); XCTAssertEqual(f.remote.records[0].fields.notes, "Local")
        XCTAssertEqual(f.applied, 1)
    }
    @MainActor func testAgreementResolvesPendingEditButNeverReversesDeletion() async throws {
        let f = TwoWayFixture(); try await f.run()
        f.planner.tasks[0].notes = "Local"; f.remote.failSave = true; await f.expectStop()
        f.remote.failSave = false
        f.planner.tasks[0].notes = "Agreed"; f.remote.edit { $0.notes = "Agreed" }
        try await f.run(); XCTAssertNil(f.ledger.value.links[f.planner.tasks[0].id]?.pending)
        let task = f.planner.tasks[0]
        f.planner.tasks = []; f.remote.beforeWrite = { f.remote.hasAccess = false }
        await f.expectStop()
        f.remote.hasAccess = true; f.remote.beforeWrite = nil
        f.planner.tasks = [task]; await f.expectStop()
        XCTAssertEqual(f.remote.removals, 0)
    }
    @MainActor func testInvalidImportsDoNotPartiallyApplyOrExport() async throws {
        for mode in 0..<6 {
            let f = TwoWayFixture(); try await f.run()
            f.planner.tasks[0].notes = "Local"
            f.remote.edit {
                switch mode {
                case 0: $0.priority = 3
                case 1: $0.title = ""
                case 2: $0.title = "Two\nlines"
                case 3: $0.due = DateComponents(year: 2026, month: 2, day: 30)
                case 4: $0.due = DateComponents(year: 2026, month: 6, day: 10, hour: 9, minute: 0)
                default: $0.alarm = f.now.addingTimeInterval(100)
                }
            }
            await f.expectStop()
            XCTAssertEqual(f.applied, 0); XCTAssertEqual(f.remote.saves, 1)
            XCTAssertEqual(f.planner.tasks[0].notes, "Local")
        }
    }
    @MainActor func testTwoWayRolloverDoesNotDeleteLinkedHistory() async throws {
        let f = TwoWayFixture(); try await f.run()
        try await f.engine.reconcile(f.planner, today: f.today.adding(days: 1))
        XCTAssertEqual(f.remote.records.count, 1); XCTAssertEqual(f.remote.removals, 0)
        XCTAssertFalse(f.ledger.value.links[f.planner.tasks[0].id]!.retired)
    }
    @MainActor func testDeleteDuringPendingCreateCannotResurrectTask() async throws {
        let f = TwoWayFixture(); f.remote.failSave = true; await f.expectStop()
        let task = f.planner.tasks[0]
        f.planner.tasks = []; f.remote.failSave = false; try await f.run()
        XCTAssertTrue(f.remote.records.isEmpty); XCTAssertEqual(f.applied, 0)
        XCTAssertTrue(f.ledger.value.links[task.id]!.retired)
        f.planner.tasks = [task]; await f.expectStop()
        XCTAssertTrue(f.remote.records.isEmpty); XCTAssertEqual(f.remote.saves, 0)
    }

    @MainActor func testIncompleteUpsertCannotDecodeAsDeletion() throws {
        let f = TwoWayFixture()
        let fields = ReminderFields(task: f.planner.tasks[0], ringOnPhone: false)
        let intent = ReminderSyncIntent(localBefore: fields, remoteBefore: fields, remoteRevision: "v1", target: fields)
        let bytes = try JSONEncoder().encode(intent)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object.removeValue(forKey: "target")
        XCTAssertThrowsError(
            try JSONDecoder().decode(ReminderSyncIntent.self, from: JSONSerialization.data(withJSONObject: object)))
        object["target"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fields))
        object.removeValue(forKey: "remoteRevision")
        XCTAssertThrowsError(
            try JSONDecoder().decode(ReminderSyncIntent.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    @MainActor func testUnknownMetadataVersionIsRejected() throws {
        let encoded = Data("{\"version\":999}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ReminderSyncLedger.self, from: encoded))
    }
}
