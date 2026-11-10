import XCTest
@testable import PlannerCore

final class PlannerUndoTests: XCTestCase {
    final class Clock {
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ seconds: Double) { time.addTimeInterval(seconds) }
    }

    final class Fixture {
        let clock = Clock()
        var planner = Planner()
        var history = PlannerUndoHistory()
        let id = UUID()
        init() {
            planner.tasks = [PlanTask(id: id, title: "Original", day: DayKey(clock.time))]
        }
        func edit(_ body: (inout PlannerEngine) throws -> Void) rethrows {
            let before = planner
            var engine = PlannerEngine(planner: planner, now: { self.clock.time })
            try body(&engine)
            planner = engine.planner
            history.record(before: before, after: planner)
        }
        func undo() { history.undo { $0(&planner) } }
        func redo() { history.redo { $0(&planner) } }
    }

    func testTimerActionsDoNotConsumeHistory() throws {
        let f = Fixture()
        try f.edit { _ = try $0.startTimer(task: f.id.uuidString, minutes: 5) }
        XCTAssertFalse(f.history.canUndo)
        f.edit { $0.planner.tasks[0].title = "Edited" }
        f.clock.advance(30.25)
        try f.edit { try $0.pauseTimer() }
        let paused = f.planner
        f.clock.advance(600)
        f.undo()
        XCTAssertEqual(f.planner.tasks[0].title, "Original")
        XCTAssertEqual(f.planner.focus, paused.focus)
        XCTAssertEqual(f.planner.focusSegments, paused.focusSegments)
        XCTAssertEqual(f.planner.tasks[0].focusedSeconds, 30.25)
        f.redo()
        XCTAssertEqual(f.planner.tasks[0].title, "Edited")
        XCTAssertEqual(f.planner.focus, paused.focus)
        try f.edit { try $0.resumeTimer() }
        f.clock.advance(4.75)
        f.edit { _ = $0.stopTimer() }
        f.undo()
        XCTAssertNil(f.planner.focus)
        XCTAssertEqual(f.planner.tasks[0].focusedSeconds, 35)
        f.redo()
        XCTAssertNil(f.planner.focus)
        XCTAssertEqual(f.planner.focusSegments.reduce(0) { $0 + $1.seconds }, 35)
    }

    func testCompletionUndoDoesNotRestartSessionOrRevertCredits() throws {
        let f = Fixture()
        try f.edit { _ = try $0.startTimer(task: f.id.uuidString, minutes: 1) }
        f.clock.advance(20)
        try f.edit { _ = try $0.complete(f.id.uuidString) }
        let ended = f.planner.focus
        XCTAssertTrue(f.planner.tasks[0].done)
        f.clock.advance(3600)
        f.undo()
        XCTAssertFalse(f.planner.tasks[0].done)
        XCTAssertEqual(f.planner.focus, ended)
        XCTAssertEqual(f.planner.tasks[0].focusedSeconds, 20)
        f.redo()
        XCTAssertTrue(f.planner.tasks[0].done)
        XCTAssertEqual(f.planner.focus, ended)
        XCTAssertEqual(f.planner.tasks[0].focusedSeconds, 20)
    }

    func testAutomaticCompletionCheckpointsAndRecoveryAreNotUndoable() throws {
        let f = Fixture()
        f.edit { $0.planner.tasks[0].notes = "Edited" }
        try f.edit { _ = try $0.startTimer(task: f.id.uuidString, minutes: 1) }
        f.clock.advance(30)
        f.edit { _ = $0.tick() }
        let checkpoint = f.planner.focus
        f.clock.advance(900)
        f.edit { _ = $0.recoverFocus() }
        f.undo()
        XCTAssertEqual(f.planner.tasks[0].notes, "")
        XCTAssertEqual(f.planner.focus?.state, .paused)
        XCTAssertEqual(f.planner.focus?.banked, checkpoint?.banked)
        f.redo()
        try f.edit { try $0.resumeTimer() }
        f.clock.advance(90)
        f.edit { _ = $0.tick() }
        XCTAssertEqual(f.planner.focus?.state, .finished)
        XCTAssertEqual(f.planner.tasks[0].focusedSeconds, 60)
        f.undo(); f.redo()
        XCTAssertEqual(f.planner.focus?.state, .finished)
        XCTAssertEqual(f.planner.tasks[0].focusedSeconds, 60)
    }

    func testExternalFieldsAndNewRecordsSurviveUndoRedo() {
        let f = Fixture()
        f.edit { $0.planner.tasks[0].title = "Edited" }
        let other = PlanTask(title: "External", day: nil)
        f.planner.tasks.append(other)
        f.planner.tasks[0].notes = "External note"
        f.planner.tasks[0].reminderLink = "synthetic-link"
        f.planner.preferences.defaultFocusMinutes = 40
        f.planner.notes.append(QuickNote(day: DayKey(f.clock.time), text: "External notepad"))
        for redo in [false, true] {
            if redo { f.redo() } else { f.undo() }
            XCTAssertEqual(f.planner.tasks[0].title, redo ? "Edited" : "Original")
            XCTAssertEqual(f.planner.tasks[0].notes, "External note")
            XCTAssertEqual(f.planner.tasks[0].reminderLink, "synthetic-link")
            XCTAssertEqual(f.planner.tasks[1], other)
            XCTAssertEqual(f.planner.notes[0].text, "External notepad")
            XCTAssertEqual(f.planner.preferences.defaultFocusMinutes, 40)
        }
    }

    func testConflictingFieldIsNotOverwrittenOrRedone() {
        let f = Fixture()
        f.edit {
            $0.planner.tasks[0].title = "Local"; $0.planner.tasks[0].notes = "Local note"
        }
        f.planner.tasks[0].title = "External title"
        f.undo()
        XCTAssertEqual(f.planner.tasks[0].title, "External title")
        XCTAssertEqual(f.planner.tasks[0].notes, "")
        f.redo()
        XCTAssertEqual(f.planner.tasks[0].title, "External title")
        XCTAssertEqual(f.planner.tasks[0].notes, "Local note")
    }

    func testSyncOnlyChangesDoNotConsumeUndoOrClearRedo() {
        let f = Fixture()
        f.edit { $0.planner.tasks[0].title = "Local" }
        f.edit { $0.planner.tasks[0].reminderLink = "synthetic-a" }
        f.undo()
        XCTAssertEqual(f.planner.tasks[0].title, "Original")
        XCTAssertEqual(f.planner.tasks[0].reminderLink, "synthetic-a")
        f.edit { $0.planner.tasks[0].reminderLink = "synthetic-b" }
        XCTAssertTrue(f.history.canRedo)
        f.redo()
        XCTAssertEqual(f.planner.tasks[0].title, "Local")
        XCTAssertEqual(f.planner.tasks[0].reminderLink, "synthetic-b")
    }

    func testFailedPersistenceLeavesBothStacksAndStateIntact() throws {
        enum Failure: Error { case write }
        let f = Fixture()
        f.edit { $0.planner.tasks[0].title = "Local" }
        let saved = f.planner
        XCTAssertThrowsError(
            try f.history.undo { change in
                var candidate = f.planner
                change(&candidate)
                throw Failure.write
            })
        XCTAssertEqual(f.planner, saved)
        XCTAssertTrue(f.history.canUndo)
        XCTAssertFalse(f.history.canRedo)
        f.undo()
        let undone = f.planner
        XCTAssertThrowsError(
            try f.history.redo { change in
                var candidate = f.planner
                change(&candidate)
                throw Failure.write
            })
        XCTAssertEqual(f.planner, undone)
        XCTAssertFalse(f.history.canUndo)
        XCTAssertTrue(f.history.canRedo)
        f.redo()
        XCTAssertEqual(f.planner, saved)
    }

    func testTaskRestorationExcludesStaleLinksAndUsesCurrentFocusLedger() {
        let f = Fixture()
        f.planner.tasks[0].reminderLink = "retired-synthetic-link"
        f.planner.tasks[0].focusedSeconds = 12
        f.planner.focusSegments = [
            FocusSegment(taskID: f.id, start: f.clock.time, end: f.clock.time.addingTimeInterval(12))
        ]
        f.edit { $0.planner.tasks.removeAll() }
        f.planner.focusSegments.append(
            FocusSegment(
                taskID: f.id, start: f.clock.time.addingTimeInterval(20), end: f.clock.time.addingTimeInterval(25)))
        f.undo()
        XCTAssertNil(f.planner.tasks[0].reminderLink)
        XCTAssertEqual(f.planner.tasks[0].focusedSeconds, 17)
        XCTAssertNil(f.planner.focus)
    }

    func testUndoInsertionPreservesTaskWithSubsequentFocusOrExternalEdits() {
        let f = Fixture()
        let new = PlanTask(title: "Added", day: nil)
        f.edit { $0.planner.tasks.append(new) }
        f.planner.tasks[1].notes = "External"
        f.undo()
        XCTAssertEqual(f.planner.tasks[1].notes, "External")
        XCTAssertFalse(f.history.canRedo)
        let second = PlanTask(title: "Second", day: nil)
        f.edit { $0.planner.tasks.append(second) }
        f.planner.tasks[2].focusedSeconds = 10
        f.undo()
        XCTAssertEqual(f.planner.tasks[2].id, second.id)
    }

    private func deletedFocusedFixture() throws -> Fixture {
        let f = Fixture()
        f.planner.tasks[0].reminderLink = "retired-synthetic-link"
        f.planner.tasks[0].agentID = "retired-synthetic-caller"
        try f.edit { _ = try $0.startTimer(task: f.id.uuidString, minutes: 1) }
        f.clock.advance(30.25)
        try f.edit { try $0.pauseTimer() }
        f.clock.advance(600)
        try f.edit { try $0.resumeTimer() }
        f.clock.advance(29.75)
        f.edit { _ = $0.tick() }
        try f.edit { _ = try $0.delete(f.id.uuidString, on: .day($0.today)) }
        return f
    }

    func testFocusedDeletionCanUndoRedoUndoWithoutRestoringRuntime() throws {
        let f = try deletedFocusedFixture()
        let ledger = f.planner.focusSegments
        XCTAssertTrue(f.planner.tasks.isEmpty)
        XCTAssertEqual(ledger.reduce(0) { $0 + $1.seconds }, 60)
        XCTAssertEqual(ledger.count, 2)
        XCTAssertLessThan(ledger[0].end, ledger[1].start)
        XCTAssertNil(f.planner.focus)
        f.undo()
        let restored = f.planner
        XCTAssertEqual(restored.tasks.first?.focusedSeconds, 60)
        XCTAssertNil(restored.tasks.first?.reminderLink)
        XCTAssertNil(restored.tasks.first?.agentID)
        for _ in 0..<2 {
            XCTAssertTrue(f.history.canRedo)
            f.redo()
            XCTAssertTrue(f.planner.tasks.isEmpty)
            XCTAssertEqual(f.planner.focusSegments, ledger)
            XCTAssertNil(f.planner.focus)
            f.undo()
            XCTAssertEqual(f.planner, restored)
        }
    }

    func testZeroCreditDeletionRoundTripDoesNotRestoreServiceIdentity() {
        let f = Fixture()
        f.planner.tasks[0].reminderLink = "retired-synthetic-link"
        f.planner.tasks[0].agentID = "retired-synthetic-caller"
        f.edit { $0.planner.tasks.removeAll() }
        f.undo()
        let restored = f.planner
        XCTAssertEqual(restored.tasks.first?.focusedSeconds, 0)
        XCTAssertNil(restored.tasks.first?.reminderLink)
        XCTAssertNil(restored.tasks.first?.agentID)
        // Service-only updates do not obstruct redo, but are never resurrected.
        f.planner.tasks[0].reminderLink = "current-synthetic-link"
        f.planner.tasks[0].agentID = "current-synthetic-caller"
        f.redo()
        XCTAssertTrue(f.planner.tasks.isEmpty)
        f.undo()
        XCTAssertEqual(f.planner, restored)
    }

    func testDeletionRedoPreservesExternalContentEdits() throws {
        let edits: [(inout PlanTask) -> Void] = [
            { $0.title = "External title" },
            { $0.notes = "External note" },
            { $0.day = nil },
            { $0.priority = .high },
        ]
        for focused in [false, true] {
            for edit in edits {
                let f: Fixture
                if focused {
                    f = try deletedFocusedFixture()
                } else {
                    f = Fixture()
                    f.edit { $0.planner.tasks.removeAll() }
                }
                f.undo()
                edit(&f.planner.tasks[0])
                let external = f.planner
                f.redo()
                XCTAssertEqual(f.planner, external)
                XCTAssertFalse(f.history.canRedo)
            }
        }
    }

    func testDeletionRedoPreservesNewFocusAfterUndo() throws {
        let f = try deletedFocusedFixture()
        f.undo()
        try f.edit { _ = try $0.startTimer(task: f.id.uuidString, minutes: 1) }
        f.clock.advance(8.5)
        f.edit { _ = $0.stopTimer() }
        XCTAssertTrue(f.history.canRedo)
        let current = f.planner
        XCTAssertEqual(current.tasks[0].focusedSeconds, 68.5)
        f.redo()
        XCTAssertEqual(f.planner, current)
        XCTAssertFalse(f.history.canRedo)
    }

    func testDeletionRedoPreservesActiveOrPausedTimerWithoutNewCredit() throws {
        for paused in [false, true] {
            let f = try deletedFocusedFixture()
            f.undo()
            try f.edit { _ = try $0.startTimer(task: f.id.uuidString, minutes: 1) }
            if paused { try f.edit { try $0.pauseTimer() } }
            let current = f.planner
            XCTAssertEqual(current.tasks[0].focusedSeconds, 60)
            XCTAssertTrue(f.history.canRedo)
            f.redo()
            XCTAssertEqual(f.planner, current)
        }
    }

    func testDeletionRedoRequiresExactCurrentLedgerNotJustEqualCredit() throws {
        let f = try deletedFocusedFixture()
        f.undo()
        let segment = f.planner.focusSegments[0]
        f.planner.focusSegments[0] = FocusSegment(
            taskID: f.id,
            start: segment.start.addingTimeInterval(-100),
            end: segment.end.addingTimeInterval(-100)
        )
        let current = f.planner
        XCTAssertEqual(current.tasks[0].focusedSeconds, 60)
        XCTAssertEqual(current.focusSegments.reduce(0) { $0 + $1.seconds }, 60)
        f.redo()
        XCTAssertEqual(f.planner, current)
    }

    func testDeletionRedoPreservesCreditChangedWithoutLedgerChange() throws {
        let f = try deletedFocusedFixture()
        f.undo()
        f.planner.tasks[0].focusedSeconds += 1
        let current = f.planner
        f.redo()
        XCTAssertEqual(f.planner, current)
    }

    func testDeletionRedoIgnoresUnrelatedFocusAndContent() throws {
        let f = try deletedFocusedFixture()
        f.undo()
        let originalLedger = f.planner.focusSegments
        let other = PlanTask(title: "Other", day: DayKey(f.clock.time))
        f.planner.tasks.append(other)
        try f.edit { _ = try $0.startTimer(task: other.id.uuidString, minutes: 1) }
        f.clock.advance(30)
        f.edit { _ = $0.tick() }
        f.planner.tasks[1].notes = "External note"
        let currentOther = f.planner.tasks[1]
        let currentFocus = f.planner.focus
        let currentLedger = f.planner.focusSegments
        f.redo()
        XCTAssertEqual(f.planner.tasks, [currentOther])
        XCTAssertEqual(f.planner.focus, currentFocus)
        XCTAssertEqual(f.planner.focusSegments, currentLedger)
        f.undo()
        XCTAssertEqual(f.planner.tasks.map(\.id), [f.id, other.id])
        XCTAssertEqual(f.planner.tasks[0].focusedSeconds, originalLedger.reduce(0) { $0 + $1.seconds })
        XCTAssertEqual(f.planner.tasks[1], currentOther)
        XCTAssertEqual(f.planner.focus, currentFocus)
        XCTAssertEqual(f.planner.focusSegments, currentLedger)
    }

    func testFreshInsertionCannotDeletePreexistingOrSubsequentFocus() throws {
        for kind in ["initial-credit", "later-credit", "ledger-only", "running", "paused"] {
            let f = Fixture()
            let added = PlanTask(title: "Added", day: DayKey(f.clock.time))
            f.edit {
                var task = added
                if kind == "initial-credit" { task.focusedSeconds = 5 }
                $0.planner.tasks.append(task)
            }
            if kind == "later-credit" { f.planner.tasks[1].focusedSeconds = 5 }
            if kind == "ledger-only" {
                f.planner.focusSegments.append(
                    FocusSegment(taskID: added.id, start: f.clock.time, end: f.clock.time.addingTimeInterval(5)))
            }
            if kind == "running" || kind == "paused" {
                try f.edit { _ = try $0.startTimer(task: added.id.uuidString, minutes: 1) }
                if kind == "paused" { try f.edit { try $0.pauseTimer() } }
            }
            let current = f.planner
            f.undo()
            XCTAssertEqual(f.planner, current, kind)
            XCTAssertFalse(f.history.canRedo, kind)
        }
    }

    func testFailedFocusedDeletionRedoRemainsRetryable() throws {
        enum Failure: Error { case write }
        let f = try deletedFocusedFixture()
        f.undo()
        let restored = f.planner
        XCTAssertThrowsError(
            try f.history.redo { body in
                var candidate = restored
                body(&candidate)
                XCTAssertTrue(candidate.tasks.isEmpty)
                throw Failure.write
            })
        XCTAssertEqual(f.planner, restored)
        XCTAssertTrue(f.history.canRedo)
        f.redo()
        XCTAssertTrue(f.planner.tasks.isEmpty)
        f.undo()
        XCTAssertEqual(f.planner, restored)
    }

    func testIndependentPreferenceNotesAndOrderingChangesSurvive() {
        let f = Fixture()
        let other = PlanTask(title: "Other", day: nil)
        f.planner.tasks.append(other)
        f.edit {
            $0.planner.tasks.reverse()
            $0.planner.preferences.defaultFocusMinutes = 50
            $0.planner.notes = [QuickNote(day: DayKey(f.clock.time), text: "Local")]
        }
        let third = PlanTask(title: "External", day: nil)
        f.planner.tasks.insert(third, at: 1)
        f.planner.preferences.catchCopies = true
        f.planner.notes.append(QuickNote(day: DayKey(f.clock.time).adding(days: 1), text: "External"))
        f.undo()
        XCTAssertEqual(f.planner.tasks.map(\.id), [f.id, third.id, other.id])
        XCTAssertTrue(f.planner.preferences.catchCopies)
        XCTAssertEqual(f.planner.preferences.defaultFocusMinutes, 25)
        XCTAssertEqual(f.planner.notes.map(\.text), ["External"])
        f.redo()
        XCTAssertEqual(f.planner.tasks.map(\.id), [other.id, third.id, f.id])
        XCTAssertTrue(f.planner.preferences.catchCopies)
    }
}
