import Foundation
import PlannerTestSupport
import XCTest
@testable import PlannerCore

final class TimeCardEngineContractTests: XCTestCase {
    func testStartPauseContinueExtendAndEndUseTheExistingPipeline() throws {
        final class Clock { var now = Fixture.now }
        let clock = Clock()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        let pipeline = PlannerCommandPipeline(
            file: file, clock: ClosurePlannerClock { clock.now }, calendar: Fixture.calendar)
        let task = try pipeline.perform(origin: .user) { try $0.addTasks(["Write the checklist"], literal: true)[0] }
            .value
        _ = try pipeline.execute(.startTimer(task.id, minutes: 45), origin: .user)
        clock.now = clock.now.addingTimeInterval(1250)
        _ = try pipeline.execute(.pauseTimer, origin: .user)
        XCTAssertEqual(try file.load().focus?.remaining(at: clock.now), 1450)
        clock.now = clock.now.addingTimeInterval(600)
        _ = try pipeline.execute(.extendTimer(5), origin: .user)
        XCTAssertEqual(try file.load().focus?.remaining(at: clock.now), 1750)
        XCTAssertEqual(try file.load().focus?.state, .paused)
        _ = try pipeline.execute(.resumeTimer, origin: .user)
        clock.now = clock.now.addingTimeInterval(1750)
        XCTAssertTrue(try pipeline.execute(.tick, origin: .background).value.flag)
        XCTAssertFalse(
            try pipeline.execute(.tick, origin: .background).value.flag, "Notify the notch once, not every tick")
        XCTAssertEqual(try file.load().focus?.state, .finished)
        XCTAssertEqual(try file.load().tasks[0].focusedSeconds, 3000)
        XCTAssertFalse(try file.load().tasks[0].done, "A block ending does not finish the task")
    }

    func testTimeCardScenariosHaveIndependentStartsAndPauseIsFrozen() throws {
        let before = try PlannerPreviewScenarios.make("today-before")
        XCTAssertEqual(before.planner.tasks.filter { $0.startAt != nil }.count, 3)
        let next = try XCTUnwrap(before.planner.tasks.filter { $0.startAt != nil }.min { $0.startAt! < $1.startAt! })
        XCTAssertEqual(next.title, "Draft the test checklist")
        XCTAssertEqual(next.minutes, 45)
        let paused = try PlannerPreviewScenarios.make("today-paused")
        XCTAssertEqual(paused.planner.focus?.state, .paused)
        XCTAssertEqual(paused.planner.focus?.remaining(at: paused.now.addingTimeInterval(600)), 1450)
        XCTAssertTrue(try PlannerPreviewScenarios.make("today-empty").planner.tasks.isEmpty)
    }
}
