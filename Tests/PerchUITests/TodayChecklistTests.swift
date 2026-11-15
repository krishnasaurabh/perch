import Foundation
import PlannerCore
@testable import PerchUI
import XCTest

final class TodayChecklistTests: XCTestCase {
    private let day: DayKey = "2026-11-13"
    private func task(_ title: String, done: Bool = false) -> PlanTask {
        PlanTask(title: title, day: day, done: done)
    }

    func testCurrentThenPersonalOpenOrderThenFinishedWithoutMutatingStorage() {
        let done = task("Done", done: true), first = task("First"), current = task("Current")
        let last = task("Last")
        let stored = [done, first, current, last]
        XCTAssertEqual(
            TodayTaskNavigation.ordered(stored, currentID: current.id).map(\.id),
            [current.id, first.id, last.id, done.id])
        XCTAssertEqual(stored.map(\.title), ["Done", "First", "Current", "Last"])
        XCTAssertEqual(
            TodayTaskNavigation.ordered(stored, currentID: UUID()).map(\.id),
            [first.id, current.id, last.id, done.id])
        XCTAssertEqual(TodayTaskNavigation.ordered(stored, currentID: done.id).last?.id, done.id)
    }

    func testFourRowsFoldAndKeyboardSelectionRevealsTheRest() {
        let tasks = (0..<7).map { task("Task \($0)") }
        XCTAssertEqual(TodayTaskNavigation.visible(tasks, expanded: false, selectedID: nil).count, 4)
        XCTAssertEqual(TodayTaskNavigation.visible(tasks, expanded: true, selectedID: nil), tasks)
        XCTAssertEqual(TodayTaskNavigation.visible(tasks, expanded: false, selectedID: tasks[6].id), tasks)
        XCTAssertEqual(TodayTaskNavigation.hiddenCount(tasks, expanded: false, selectedID: nil), 3)
        XCTAssertEqual(TodayTaskNavigation.hiddenCount([], expanded: false, selectedID: nil), 0)
    }

    func testReorderUsesOpenPersonalOrderAndStopsAtBothEdges() {
        let first = task("First"), current = task("Current"), last = task("Last")
        let tasks = [current, first, last, task("Done", done: true)]
        XCTAssertNil(TodayTaskNavigation.reorder(tasks, currentID: current.id, selectedID: first.id, offset: -1))
        XCTAssertNil(TodayTaskNavigation.reorder(tasks, currentID: current.id, selectedID: current.id, offset: 1))
        XCTAssertNil(TodayTaskNavigation.reorder(tasks, currentID: current.id, selectedID: last.id, offset: 1))
        XCTAssertEqual(
            TodayTaskNavigation.reorder(tasks, currentID: current.id, selectedID: last.id, offset: -1)?.beforeID,
            first.id)
        XCTAssertNil(
            TodayTaskNavigation.reorder(tasks, currentID: current.id, selectedID: first.id, offset: 1)?.beforeID)
        XCTAssertNotNil(TodayTaskNavigation.reorder(tasks, currentID: current.id, selectedID: first.id, offset: 1))
    }

    func testCaptureIndentIsOneLevelAndOutdentRestoresTaskMode() {
        var capture = TodayTaskCapture()
        XCTAssertFalse(capture.indent(parentID: nil))
        let id = UUID()
        XCTAssertTrue(capture.indent(parentID: id))
        XCTAssertEqual(capture.parentID, id)
        XCTAssertFalse(capture.indent(parentID: UUID()))
        XCTAssertTrue(capture.outdent())
        XCTAssertNil(capture.parentID)
        XCTAssertFalse(capture.outdent())
    }

    func testNextStepSkipsFinishedAndReturnsNilWhenAllDone() {
        let steps = [Subtask(title: "First", done: true), Subtask(title: "Next"), Subtask(title: "Later")]
        XCTAssertEqual(TodayTaskNavigation.nextStep(in: steps), steps[1].id)
        XCTAssertNil(TodayTaskNavigation.nextStep(in: steps.map { Subtask(title: $0.title, done: true) }))
    }

    func testSubmissionAndParkingAreAtomicAndUndoable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = ISO8601DateFormatter().date(from: "2026-11-13T09:12:00Z")!
        let pipeline = PlannerCommandPipeline(
            file: PlannerFile(url: root.appendingPathComponent("planner.json")),
            clock: ClosurePlannerClock { now })
        let parent = try pipeline.perform(origin: .user) {
            try TodayTaskCapture.submit("Review at 1:30 PM for 20 min", parentID: nil, on: .day(day), commands: $0)
        }.value[0]
        XCTAssertNotNil(parent.startAt)
        XCTAssertEqual(parent.minutes, 20)
        let step = try pipeline.perform(origin: .user) {
            try TodayTaskCapture.submit("Check the links", parentID: parent.id, on: .day(day), commands: $0)
        }.state.tasks[0]
        XCTAssertEqual(step.steps.map(\.title), ["Check the links"])
        XCTAssertEqual(step.startAt, parent.startAt)
        XCTAssertEqual(try pipeline.undo()?.tasks[0].steps.count, 0)
        XCTAssertEqual(try pipeline.redo()?.tasks[0].steps.count, 1)
        let parked = try pipeline.perform(origin: .user) {
            try TodayTaskNavigation.park(parent.id, commands: $0)
        }.state
        XCTAssertTrue(parked.tasks.isEmpty)
        XCTAssertEqual(parked.parkedThoughts.map(\.text), [parent.title])
        let restored = try XCTUnwrap(pipeline.undo())
        XCTAssertEqual(restored.tasks[0].id, parent.id)
        XCTAssertTrue(restored.parkedThoughts.isEmpty)
        XCTAssertThrowsError(
            try pipeline.perform(origin: .user) {
                try TodayTaskCapture.submit("Orphan", parentID: UUID(), on: .day(day), commands: $0)
            })
        XCTAssertEqual(try pipeline.inspect { $0.planner.tasks[0].steps.count }, 1)
    }
}
