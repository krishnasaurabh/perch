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
        f.edit { $0.planner.tasks[0].title = "Local"; $0.planner.tasks[0].notes = "Local note" }
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
        XCTAssertThrowsError(try f.history.undo { change in
            var candidate = f.planner
            change(&candidate)
            throw Failure.write
        })
        XCTAssertEqual(f.planner, saved)
        XCTAssertTrue(f.history.canUndo)
        XCTAssertFalse(f.history.canRedo)
        f.undo()
        let undone = f.planner
        XCTAssertThrowsError(try f.history.redo { change in
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
        f.planner.focusSegments = [FocusSegment(taskID: f.id, start: f.clock.time, end: f.clock.time.addingTimeInterval(12))]
        f.edit { $0.planner.tasks.removeAll() }
        f.planner.focusSegments.append(FocusSegment(taskID: f.id, start: f.clock.time.addingTimeInterval(20), end: f.clock.time.addingTimeInterval(25)))
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
