import XCTest
import PlannerCore
@testable import PerchUI

final class TodayTaskNavigationTests: XCTestCase {
    private let ids = (0..<30).map { _ in UUID() }

    func testEmptyOrUnknownRowsDoNotInventFocus() {
        XCTAssertNil(TodayTaskNavigation.neighbor(in: [], from: ids[0], offset: 1))
        XCTAssertNil(TodayTaskNavigation.neighbor(in: ids, from: UUID(), offset: -1))
        XCTAssertNil(TodayTaskNavigation.afterRemoval(of: ids[0], previous: ids, remaining: []))
    }

    func testThreeRowsFollowVisualOrderAndStopAtEdges() {
        let rows = Array(ids.prefix(3))
        XCTAssertEqual(TodayTaskNavigation.neighbor(in: rows, from: rows[0], offset: 1), rows[1])
        XCTAssertEqual(TodayTaskNavigation.neighbor(in: rows, from: rows[2], offset: -1), rows[1])
        XCTAssertEqual(TodayTaskNavigation.neighbor(in: rows, from: rows[0], offset: -1), rows[0])
        XCTAssertEqual(TodayTaskNavigation.neighbor(in: rows, from: rows[2], offset: 1), rows[2])
    }

    func testManyRowsRetainOrderedKeyboardReachability() {
        var focused = ids[0]
        for next in ids.dropFirst() {
            focused = TodayTaskNavigation.neighbor(in: ids, from: focused, offset: 1)!
            XCTAssertEqual(focused, next)
        }
        for previous in ids.dropLast().reversed() {
            focused = TodayTaskNavigation.neighbor(in: ids, from: focused, offset: -1)!
            XCTAssertEqual(focused, previous)
        }
    }

    func testDeletedOrCompletedRowSelectsNextThenPrevious() {
        let rows = Array(ids.prefix(3))
        XCTAssertEqual(
            TodayTaskNavigation.afterRemoval(
                of: rows[1], previous: rows,
                remaining: [rows[0], rows[2]]), rows[2])
        XCTAssertEqual(
            TodayTaskNavigation.afterRemoval(
                of: rows[2], previous: rows,
                remaining: [rows[0], rows[1]]), rows[1])
        XCTAssertEqual(
            TodayTaskNavigation.afterRemoval(
                of: rows[0], previous: rows,
                remaining: [rows[1], rows[2]]), rows[1])
    }

    func testOtherEditsDoNotMoveSurvivingFocus() {
        XCTAssertEqual(
            TodayTaskNavigation.afterRemoval(
                of: ids[10], previous: ids,
                remaining: Array(ids.dropFirst())), ids[10])
    }

    func testActualCompletionAndDeletionUseRemainingDisplayedOrder() throws {
        var engine = PlannerEngine(planner: Planner())
        let tasks = try engine.addTasks(["Inspect seedlings", "Wash seed trays", "Label new pots"])
        let before = tasks.map(\.id)
        try engine.complete(tasks[1].id)
        let active = engine.tasks(on: .day(engine.today)).filter { !$0.done }.map(\.id)
        XCTAssertEqual(
            TodayTaskNavigation.afterRemoval(of: tasks[1].id, previous: before, remaining: active), tasks[2].id)
        try engine.delete(tasks[2].id, on: .day(engine.today))
        let afterDelete = engine.tasks(on: .day(engine.today)).filter { !$0.done }.map(\.id)
        XCTAssertEqual(
            TodayTaskNavigation.afterRemoval(of: tasks[2].id, previous: active, remaining: afterDelete), tasks[0].id)
        XCTAssertEqual(TodayTabs.resolved(.completed, completedCount: 1), .completed)
    }
}
