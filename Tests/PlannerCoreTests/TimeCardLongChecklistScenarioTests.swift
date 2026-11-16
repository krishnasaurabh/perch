import Foundation
import PlannerCore
import XCTest

final class TimeCardLongChecklistScenarioTests: XCTestCase {
    func testLongChecklistSnapshotsKeepAllStepsInRunningAndPausedStates() throws {
        for (name, state) in [
            ("today-running-many-steps", FocusSession.State.running),
            ("today-paused-many-steps", FocusSession.State.paused),
        ] {
            let fixture = try PlannerPreviewScenarios.make(name)
            let focus = try XCTUnwrap(fixture.planner.focus)
            let task = try XCTUnwrap(fixture.planner.tasks.first { $0.id == focus.taskID })
            XCTAssertEqual(focus.state, state)
            XCTAssertEqual(task.steps.count, 20)
            XCTAssertEqual(task.steps.filter(\.done).count, 7)
            XCTAssertEqual(Set(task.steps.map(\.id)).count, 20)
            XCTAssertEqual(focus.remaining(at: fixture.now), 1450)
        }
    }
}
