import Foundation
import PlannerTestSupport
import XCTest
@testable import PlannerCore

final class ParkingLotWorkflowTests: XCTestCase {
    func testParkingDuringABlockSurvivesReloadAndOnlyPromotionCreatesATask() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        let pipeline = PlannerCommandPipeline(
            file: file, clock: ClosurePlannerClock { Fixture.now }, calendar: Fixture.calendar)
        let active = try pipeline.perform(origin: .user) { commands in
            let task = try commands.addTasks(["Write the outline"], literal: true)[0]
            try commands.startTimer(task: task.id, minutes: 25)
            return task
        }.value
        let before = try file.load()
        let thought = try pipeline.perform(origin: .user) { try $0.parkThought("Call tomorrow at 9 for 20 min") }.value
        let parked = try file.load()
        XCTAssertEqual(parked.tasks, before.tasks)
        XCTAssertEqual(parked.focus, before.focus)
        XCTAssertEqual(parked.parkedThoughts, [thought])
        let reloaded = PlannerCommandPipeline(
            file: file, clock: ClosurePlannerClock { Fixture.now }, calendar: Fixture.calendar)
        let promoted = try reloaded.perform(origin: .user) { try $0.promoteThought(thought.id, on: $0.today) }.value
        XCTAssertEqual(promoted.title, thought.text)
        XCTAssertEqual(promoted.day, before.tasks[0].day)
        XCTAssertNil(promoted.startAt)
        XCTAssertNil(promoted.remindAt)
        XCTAssertEqual(try file.load().focus?.taskID, active.id)
        XCTAssertTrue(try file.load().parkedThoughts.isEmpty)
        _ = try reloaded.undo()
        XCTAssertEqual(try file.load().parkedThoughts, [thought])
        XCTAssertEqual(try file.load().tasks, before.tasks)
    }

    func testRunningPreviewSeedsRealThoughtsAndEmptyStatesStayEmpty() throws {
        let running = try PlannerPreviewScenarios.make("today-running")
        XCTAssertEqual(running.planner.parkedThoughts.map(\.text), ["Order printer ink", "Reply to the landlord"])
        XCTAssertEqual(Set(running.planner.parkedThoughts.map(\.id)).count, 2)
        XCTAssertEqual(
            try PlannerPreviewScenarios.make("today-running").planner.parkedThoughts, running.planner.parkedThoughts)
        for name in ["today-before", "today-empty"] {
            XCTAssertTrue(try PlannerPreviewScenarios.make(name).planner.parkedThoughts.isEmpty)
        }
    }
}
