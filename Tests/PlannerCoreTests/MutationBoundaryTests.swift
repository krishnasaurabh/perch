import Foundation
import XCTest
@testable import PlannerCore

final class MutationBoundaryTests: XCTestCase {
    func testReorderCannotRewritePastDay() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = DayKey(now)
        let old = PlanTask(title: "Archived task", day: today.adding(days: -1))
        let current = PlanTask(title: "Current task", day: today)
        var planner = Planner()
        planner.tasks = [old, current]
        var engine = PlannerEngine(planner: planner, now: { now })
        XCTAssertThrowsError(try engine.reorder(old.id, before: nil))
        XCTAssertEqual(engine.planner.tasks, planner.tasks)
    }

    func testStopwatchCannotAttachToMissingTask() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var engine = PlannerEngine(planner: Planner(), now: { now })
        XCTAssertThrowsError(try engine.startStopwatch(taskID: UUID()))
        XCTAssertNil(engine.planner.focus)
    }
}
