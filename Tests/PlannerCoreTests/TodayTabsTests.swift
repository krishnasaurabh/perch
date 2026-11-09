import XCTest
@testable import PlannerCore

final class TodayTabsTests: XCTestCase {
    func testCompletedPillHiddenUntilSomethingIsDone() {
        XCTAssertEqual(TodayTabs.visible(completedCount: 0), [.active])
        XCTAssertEqual(TodayTabs.visible(completedCount: 1), [.active, .completed])
        XCTAssertEqual(TodayTabs.visible(completedCount: 7), [.active, .completed])
    }

    func testSelectionFallsBackToToDoWhenCompletedPillDisappears() {
        XCTAssertEqual(TodayTabs.resolved(.completed, completedCount: 0), .active)
        XCTAssertEqual(TodayTabs.resolved(.active, completedCount: 0), .active)
    }

    func testCompletedStaysReachableOnceATaskIsDone() {
        XCTAssertEqual(TodayTabs.resolved(.completed, completedCount: 1), .completed)
        XCTAssertEqual(TodayTabs.resolved(.active, completedCount: 1), .active)
    }

    /// The real path: tick a task, look at Completed, then reopen the only finished task.
    func testReopeningTheOnlyFinishedTaskReturnsToToDo() throws {
        var e = PlannerEngine(planner: Planner())
        _ = try e.addTasks(["Sort the seed packets", "Rinse the paint tray"])
        func doneToday() -> Int { e.tasks(on: .day(e.today)).filter(\.done).count }

        XCTAssertEqual(TodayTabs.visible(completedCount: doneToday()), [.active])
        _ = try e.complete("Rinse the paint tray")
        XCTAssertEqual(TodayTabs.visible(completedCount: doneToday()), [.active, .completed])
        XCTAssertEqual(TodayTabs.resolved(.completed, completedCount: doneToday()), .completed)
        _ = try e.reopen("Rinse the paint tray")
        XCTAssertEqual(TodayTabs.visible(completedCount: doneToday()), [.active])
        XCTAssertEqual(TodayTabs.resolved(.completed, completedCount: doneToday()), .active)
    }
}
