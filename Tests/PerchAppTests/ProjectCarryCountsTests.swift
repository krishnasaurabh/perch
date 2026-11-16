import Foundation
import PlannerCore
import XCTest
@testable import PerchApp

final class ProjectCarryCountsTests: XCTestCase {
    func testFinishingTwiceCarriedTaskLeavesNoOpenOrNextAndFullProgress() throws {
        let project = TaskProject(name: "Work")
        var engine = try carriedTaskEngine(projectID: project.id)
        let current = try XCTUnwrap(engine.planner.tasks.last)
        XCTAssertEqual(current.carryCount, 2)
        XCTAssertTrue(engine.overdue().isEmpty)
        XCTAssertEqual(engine.planner.dismissedOverdue.count, 2)
        XCTAssertThrowsError(try engine.complete(engine.planner.tasks[0].id))

        let before = ProjectCardModel(project: project, tasks: engine.planner.tasks, today: engine.today)
        XCTAssertEqual(before.open, 1)
        XCTAssertEqual(before.next?.id, current.id)
        XCTAssertEqual(before.progress, 0)

        _ = try engine.execute(.complete(current.id))
        let finished = ProjectCardModel(project: project, tasks: engine.planner.tasks, today: engine.today)
        XCTAssertEqual(finished.open, 0)
        XCTAssertEqual(finished.done, 1)
        XCTAssertEqual(finished.progress, 1)
        XCTAssertNil(finished.next)
        XCTAssertEqual(engine.planner.tasks.filter { !$0.done }.count, 2)
    }

    func testUnfiledCountExcludesCarrySourcesBeforeAndAfterCompletion() throws {
        var engine = try carriedTaskEngine(projectID: nil)
        let current = try XCTUnwrap(engine.planner.tasks.last)
        XCTAssertEqual(
            ProjectCardModel.openTasks(engine.planner.tasks, projectID: nil, today: engine.today).map(\.id),
            [current.id])
        _ = try engine.execute(.complete(current.id))
        XCTAssertTrue(ProjectCardModel.openTasks(engine.planner.tasks, projectID: nil, today: engine.today).isEmpty)
        XCTAssertEqual(engine.planner.tasks.filter { !$0.done }.count, 2)
    }

    func testDateEligibilityKeepsInboxTodayAndFutureInSavedOrderAndAllFinishedHistory() {
        let project = TaskProject(name: "Work")
        let tasks = [
            PlanTask(title: "Earlier day", day: "2026-11-12", projectID: project.id),
            PlanTask(title: "Tomorrow first", day: "2026-11-14", projectID: project.id),
            PlanTask(title: "Inbox second", day: nil, projectID: project.id),
            PlanTask(title: "Today third", day: "2026-11-13", projectID: project.id),
            PlanTask(title: "Finished last week", day: "2026-11-06", done: true, projectID: project.id),
            PlanTask(title: "Finished today", day: "2026-11-13", done: true, projectID: project.id),
            PlanTask(title: "Other project", day: "2026-11-13", projectID: UUID()),
            PlanTask(title: "No project", day: nil),
        ]
        let value = ProjectCardModel(project: project, tasks: tasks, today: "2026-11-13")
        XCTAssertEqual(value.open, 3)
        XCTAssertEqual(value.done, 2)
        XCTAssertEqual(value.progress, 0.4)
        XCTAssertEqual(value.next?.id, tasks[1].id)
        XCTAssertEqual(
            ProjectCardModel.openTasks(tasks, projectID: project.id, today: "2026-11-13").map(\.id),
            [tasks[1].id, tasks[2].id, tasks[3].id])
        XCTAssertEqual(
            ProjectCardModel.openTasks(tasks, projectID: nil, today: "2026-11-13").map(\.id), [tasks[7].id])

        let nextDay = ProjectCardModel(project: project, tasks: tasks, today: "2026-11-14")
        XCTAssertEqual(nextDay.open, 2)
        XCTAssertEqual(nextDay.done, 2)
        XCTAssertEqual(nextDay.progress, 0.5)
        XCTAssertEqual(nextDay.next?.id, tasks[1].id)
    }

    private func carriedTaskEngine(projectID: UUID?) throws -> PlannerEngine {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 12)))
        let original = PlanTask(title: "Read the notes", day: "2026-11-11", projectID: projectID)
        var planner = Planner()
        planner.tasks = [original]
        let firstCarryTime = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        var engine = PlannerEngine(planner: planner, now: { firstCarryTime }, calendar: calendar)
        let first = try XCTUnwrap(engine.execute(.carryForward([original.id], engine.today)).tasks.first)
        engine.now = { now }
        _ = try engine.execute(.carryForward([first.id], engine.today))
        return engine
    }
}
