import Foundation
import PlannerTestSupport
import XCTest
@testable import PlannerCore

final class TaskStartAndParkingTests: XCTestCase {
    private var directory: URL!
    private var file: PlannerFile!
    private var pipeline: PlannerCommandPipeline!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        pipeline = PlannerCommandPipeline(
            file: file, clock: ClosurePlannerClock { Fixture.now }, calendar: Fixture.calendar)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testCaptureSeparatesBlockStartFromExistingReminderGrammar() throws {
        let capture = TaskCapture(now: Fixture.date("2026-11-09 09:00"), calendar: Fixture.calendar)
        let block = capture.parse("Write outline at 1:30 for 20 min")
        XCTAssertEqual(block.title, "Write outline")
        XCTAssertEqual(Fixture.hm(block.startAt), "2026-11-09 13:30")
        XCTAssertEqual(block.minutes, 20)
        XCTAssertNil(block.remindAt)
        XCTAssertEqual(Fixture.hm(capture.parse("Call at 1:30").remindAt), "2026-11-09 13:30")
        XCTAssertNil(capture.parse("Call at 1:30").startAt)
        XCTAssertNotNil(capture.parse("Call in 20 minutes").remindAt)
        XCTAssertNil(capture.parse("Write \"at 1:30 for 20 min\"").startAt)
        XCTAssertNil(capture.parse("Write for 20 min").startAt)
        let explicit = try capture.parse("Write tomorrow at 1:30 for 20 min", languageCode: "en")
        XCTAssertEqual(Fixture.hm(explicit.startAt), "2026-11-10 13:30")
    }

    func testStartSetMoveClearUndoAndReminderIndependence() throws {
        let task = try pipeline.perform(origin: .user) {
            try $0.addTasks(["Write outline"], literal: true)[0]
        }.value
        let reminder = Fixture.date("2026-11-09 19:00")
        var changes = TaskChanges()
        changes.remindAt = .set(reminder)
        try pipeline.execute(.editTask(task.id, changes), origin: .user)
        let first = Fixture.date("2026-11-09 13:30")
        try pipeline.execute(.setStart(task.id, first), origin: .user)
        XCTAssertEqual(try file.load().tasks[0].startAt, first, "A start earlier today is valid")
        let second = Fixture.date("2026-11-09 17:00")
        try pipeline.execute(.setStart(task.id, second), origin: .user)
        try pipeline.execute(.setStart(task.id, nil), origin: .user)
        XCTAssertNil(try file.load().tasks[0].startAt)
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().tasks[0].startAt, second)
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().tasks[0].startAt, first)
        _ = try pipeline.redo()
        XCTAssertEqual(try file.load().tasks[0].startAt, second)
        XCTAssertEqual(try file.load().tasks[0].remindAt, reminder)
    }

    func testStartValidationAndMovesFollowLogicalDayAcrossDST() throws {
        let task = try pipeline.perform(origin: .user) { try $0.addTasks(["Write"], literal: true)[0] }.value
        let before = try file.load()
        for date in [Fixture.date("2026-11-08 17:00"), Date(timeIntervalSince1970: .infinity)] {
            XCTAssertThrowsError(try pipeline.execute(.setStart(task.id, date), origin: .user))
            XCTAssertEqual(try file.load(), before)
        }
        try pipeline.execute(.setStart(task.id, Fixture.date("2026-11-09 17:00")), origin: .user)
        try pipeline.execute(.move(task.id, .day("2026-11-10")), origin: .user)
        XCTAssertEqual(Fixture.hm(try file.load().tasks[0].startAt), "2026-11-10 17:00")
        try pipeline.execute(.move(task.id, .inbox), origin: .user)
        XCTAssertNil(try file.load().tasks[0].startAt)
        XCTAssertThrowsError(try pipeline.execute(.setStart(task.id, Fixture.now), origin: .user))

        var planner = Planner()
        planner.preferences.resetHour = 4
        planner.tasks = [PlanTask(title: "Night", day: "2027-03-12", startAt: Fixture.date("2027-03-13 02:30"))]
        var engine = PlannerEngine(
            planner: planner, now: { Fixture.date("2027-03-12 10:00") }, calendar: Fixture.calendar)
        try engine.execute(.move(planner.tasks[0].id, .day("2027-03-13")))
        XCTAssertEqual(Fixture.hm(engine.planner.tasks[0].startAt), "2027-03-14 03:00")
    }

    func testCapturePersistsStartWithoutSchedulingReminder() throws {
        let result = try pipeline.execute(
            .addTasks(["Write at 4:30 for 20 min"], day: nil, literal: false, agentID: nil), origin: .user)
        XCTAssertEqual(Fixture.hm(result.value.tasks[0].startAt), "2026-11-09 16:30")
        XCTAssertNil(result.value.tasks[0].remindAt)
        XCTAssertEqual(try file.load().tasks, result.state.tasks)
        let exported = directory.appendingPathComponent("export.json")
        try file.export(to: exported)
        XCTAssertEqual(try PlannerFile.decodeDocument(Data(contentsOf: exported)).tasks, result.state.tasks)
    }

    func testParkingAddReorderRemoveEmptyAndUndo() throws {
        let first = try pipeline.execute(.parkThought("  First thought  "), origin: .user).value.thoughts[0]
        let second = try pipeline.execute(.parkThought("Second thought"), origin: .user).value.thoughts[0]
        XCTAssertEqual(first.text, "First thought")
        XCTAssertEqual(first.createdAt, Fixture.now)
        XCTAssertTrue(try file.load().tasks.isEmpty)
        try pipeline.execute(.reorderThought(second.id, before: first.id), origin: .user)
        XCTAssertEqual(try file.load().parkedThoughts.map(\.id), [second.id, first.id])
        try pipeline.execute(.removeThought(first.id), origin: .user)
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().parkedThoughts.map(\.id), [second.id, first.id])
        try pipeline.execute(.emptyParkingLot, origin: .user)
        XCTAssertTrue(try file.load().parkedThoughts.isEmpty)
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().parkedThoughts.map(\.id), [second.id, first.id])
        _ = try pipeline.redo()
        XCTAssertTrue(try file.load().parkedThoughts.isEmpty)
    }

    func testPromotionIsLiteralAtomicAndUndoable() throws {
        let thought = try pipeline.execute(.parkThought("Think tomorrow at 9 for 20 min"), origin: .user).value
            .thoughts[0]
        let before = try file.load()
        XCTAssertThrowsError(
            try pipeline.execute(.promoteThought(thought.id, day: "2026-11-08", agentID: nil), origin: .user))
        XCTAssertEqual(try file.load(), before)
        let result = try pipeline.execute(
            .promoteThought(thought.id, day: "2026-11-11", agentID: "test-client"), origin: .user)
        let task = try XCTUnwrap(result.value.tasks.first)
        XCTAssertEqual(task.day, "2026-11-11")
        XCTAssertEqual(task.title, thought.text)
        XCTAssertNil(task.startAt)
        XCTAssertNil(task.remindAt)
        XCTAssertEqual(task.agentID, "test-client")
        XCTAssertTrue(result.state.parkedThoughts.isEmpty)
        XCTAssertThrowsError(try pipeline.execute(.promoteThought(thought.id, day: nil, agentID: nil), origin: .user))
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().parkedThoughts, [thought])
        XCTAssertTrue(try file.load().tasks.isEmpty)
        _ = try pipeline.redo()
        XCTAssertTrue(try file.load().parkedThoughts.isEmpty)
        XCTAssertEqual(try file.load().tasks.first?.id, task.id)
    }

    func testParkingRejectsInvalidInputWithoutMutation() throws {
        try file.save(Planner())
        let before = try file.load()
        for text in [" \n\t", String(repeating: "x", count: 20_001)] {
            XCTAssertThrowsError(try pipeline.execute(.parkThought(text), origin: .user))
            XCTAssertEqual(try file.load(), before)
        }
        XCTAssertThrowsError(try pipeline.execute(.removeThought(UUID()), origin: .user))
        XCTAssertThrowsError(try pipeline.execute(.reorderThought(UUID(), before: nil), origin: .user))
    }

    func testBringOverUsesLastPopulatedDayIncludingDismissedButNotAlreadyCarried() throws {
        var planner = Planner()
        planner.tasks = [
            PlanTask(title: "Older", day: "2026-11-05"),
            PlanTask(title: "Done", day: "2026-11-07", done: true),
            PlanTask(
                title: "Waiting", day: "2026-11-07", minutes: 20, steps: [Subtask(title: "Draft", done: true)],
                carryCount: 2),
        ]
        planner.dismissedOverdue = [planner.tasks[2].id]
        planner.preferences.carryMode = .never
        try file.save(planner)
        XCTAssertEqual(try pipeline.inspect { $0.read.bringOverCandidates().map(\.title) }, ["Waiting"])
        let brought = try pipeline.execute(.bringOver, origin: .user).value.tasks
        XCTAssertEqual(brought.count, 1)
        XCTAssertEqual(brought[0].day, "2026-11-09")
        XCTAssertEqual(brought[0].carriedFrom, "2026-11-07")
        XCTAssertEqual(brought[0].carryCount, 3)
        XCTAssertTrue(brought[0].steps[0].done)
        XCTAssertTrue(try pipeline.inspect { $0.read.bringOverCandidates().isEmpty })
        XCTAssertTrue(try pipeline.execute(.bringOver, origin: .user).value.tasks.isEmpty)
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load(), planner)
        _ = try pipeline.redo()
        XCTAssertEqual(try file.load().tasks.count, 4)
        try file.mutate { $0.preferences.carryMode = .auto }
        XCTAssertTrue(try pipeline.inspect { $0.read.bringOverCandidates().isEmpty })
    }

    func testReminderReschedulingMovesTheStartWithItsTask() throws {
        let task = try pipeline.perform(origin: .user) { try $0.addTasks(["Write"], literal: true)[0] }.value
        try pipeline.execute(.setStart(task.id, Fixture.date("2026-11-09 17:00")), origin: .user)
        var changes = TaskChanges()
        changes.remindAt = .set(Fixture.date("2026-11-10 18:00"))
        try pipeline.execute(.editTask(task.id, changes), origin: .user)
        XCTAssertEqual(Fixture.hm(try file.load().tasks[0].startAt), "2026-11-10 17:00")
        var edit = TaskEdit()
        edit.remindAt = "2026-11-11 18:00"
        try pipeline.execute(.update(task.id, edit), origin: .user)
        XCTAssertEqual(Fixture.hm(try file.load().tasks[0].startAt), "2026-11-11 17:00")
        _ = try pipeline.undo()
        XCTAssertEqual(Fixture.hm(try file.load().tasks[0].startAt), "2026-11-10 17:00")
    }

    func testRepeatingBlocksInheritTheirWallTimeThroughCommands() throws {
        let task = try pipeline.perform(origin: .user) {
            try $0.addTasks(["Write today at 4:30 for 20 min every day"])[0]
        }.value
        let tomorrow: DayKey = "2026-11-10"
        try pipeline.execute(.lifecycle(.openDay(tomorrow)), origin: .background)
        let child = try XCTUnwrap(try file.load().tasks.first { $0.id != task.id })
        XCTAssertEqual(Fixture.hm(child.startAt), "2026-11-10 16:30")
        XCTAssertEqual(child.minutes, 20)
        XCTAssertNil(child.remindAt)
    }

    func testBatchPromotionUndoIsAtomicWhenOneTaskWasEdited() throws {
        let a = try pipeline.execute(.parkThought("A"), origin: .user).value.thoughts[0]
        let b = try pipeline.execute(.parkThought("B"), origin: .user).value.thoughts[0]
        let task = try pipeline.perform(origin: .user) {
            let promoted = try $0.promoteThought(a.id)
            _ = try $0.rename(promoted.id, on: .day($0.today), to: "Edited A")
            _ = try $0.promoteThought(b.id)
            return promoted
        }.value
        XCTAssertEqual(try file.load().tasks.first?.parkedFrom, a.id)
        XCTAssertEqual(try file.load().tasks.first?.id, task.id)
        try file.mutate { $0.tasks[0].notes = "External" }
        let before = try file.load()
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load(), before)
    }

    func testBringOverExcludesRepeatAlreadyPresentToday() throws {
        var planner = Planner()
        planner.tasks = [PlanTask(title: "Daily", day: "2026-11-08", repeatRule: .daily)]
        var engine = PlannerEngine(planner: planner, now: { Fixture.now }, calendar: Fixture.calendar)
        try engine.execute(.lifecycle(.openDay(engine.today)))
        XCTAssertTrue(engine.bringOverCandidates().isEmpty)
        XCTAssertTrue(try engine.execute(.bringOver).tasks.isEmpty)
    }

    func testStartUndoPreservesExternalChangesAndFocusCredit() throws {
        let task = try pipeline.perform(origin: .user) { try $0.addTasks(["Write"], literal: true)[0] }.value
        try pipeline.execute(.setStart(task.id, Fixture.date("2026-11-09 17:00")), origin: .user)
        try file.mutate {
            $0.tasks[0].notes = "External note"
            $0.tasks[0].focusedSeconds = 20
            $0.tasks[0].unloggedFocusedSeconds = 20
        }
        _ = try pipeline.undo()
        XCTAssertNil(try file.load().tasks[0].startAt)
        XCTAssertEqual(try file.load().tasks[0].notes, "External note")
        XCTAssertEqual(try file.load().tasks[0].focusedSeconds, 20)
    }

    func testPromotionUndoDoesNotDuplicateAThoughtWhenTaskWasEdited() throws {
        let thought = try pipeline.execute(.parkThought("Idea"), origin: .user).value.thoughts[0]
        let task = try pipeline.execute(.promoteThought(thought.id, day: nil, agentID: nil), origin: .user).value.tasks[
            0]
        try file.mutate { $0.tasks[0].notes = "External note" }
        _ = try pipeline.undo()
        XCTAssertTrue(try file.load().parkedThoughts.isEmpty)
        XCTAssertEqual(try file.load().tasks.first?.id, task.id)
        XCTAssertEqual(try file.load().tasks.first?.notes, "External note")
        XCTAssertFalse(pipeline.canRedo)
    }

    func testBringOverDistinguishesIdenticalTitlesAndRetainsStartTime() throws {
        var planner = Planner()
        planner.tasks = [
            PlanTask(title: "Same", day: "2026-11-08", startAt: Fixture.date("2026-11-08 10:00")),
            PlanTask(title: "Same", day: "2026-11-08"),
        ]
        try file.save(planner)
        let first = try pipeline.execute(.carryForward([planner.tasks[0].id], "2026-11-09"), origin: .user).value.tasks[
            0]
        XCTAssertEqual(first.carriedTaskID, planner.tasks[0].id)
        XCTAssertEqual(Fixture.hm(first.startAt), "2026-11-09 10:00")
        XCTAssertEqual(try pipeline.inspect { $0.read.bringOverCandidates().map(\.id) }, [planner.tasks[1].id])
        XCTAssertEqual(try pipeline.execute(.bringOver, origin: .user).value.tasks.count, 1)
    }

    func testLegacyWritesParkOnlyNewLinesAndKeepOriginalText() throws {
        try pipeline.perform(origin: .user) { try $0.writeNotepad(on: $0.today, text: "  First  \nFirst") }
        XCTAssertEqual(try file.load().parkedThoughts.map(\.text), ["  First  ", "First"])
        try pipeline.perform(origin: .user) {
            try $0.writeNotepad(on: $0.today, text: "  First  \nFirst", mode: "replace")
        }
        XCTAssertEqual(try file.load().parkedThoughts.count, 2)
        try pipeline.perform(origin: .user) { try $0.writeNotepad(on: $0.today, text: "Second", mode: "replace") }
        XCTAssertEqual(try file.load().parkedThoughts.map(\.text), ["  First  ", "First", "Second"])
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().parkedThoughts.map(\.text), ["  First  ", "First"])
        XCTAssertEqual(try file.load().notes.first?.text, "  First  \nFirst")
    }

    func testBringOverDoesNotSkipACompletedLastDayOrMutateOnRead() throws {
        var planner = Planner()
        planner.tasks = [
            PlanTask(title: "Older", day: "2026-11-05"), PlanTask(title: "Done", day: "2026-11-08", done: true),
        ]
        try file.save(planner)
        let bytes = try Data(contentsOf: file.url)
        XCTAssertTrue(try pipeline.inspect { $0.read.bringOverCandidates().isEmpty })
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
    }
}
