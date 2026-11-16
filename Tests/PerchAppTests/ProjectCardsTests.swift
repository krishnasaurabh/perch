import Foundation
import XCTest
import PlannerCore
@testable import PerchUI
@testable import PerchApp

final class ProjectCardsTests: XCTestCase {
    func testCountsUseEveryTaskAndNextUsesSavedOpenTaskOrder() {
        let project = TaskProject(name: "Work")
        let tasks = [
            PlanTask(title: "Finished", day: "2026-11-11", done: true, projectID: project.id),
            PlanTask(title: "First open", day: nil, projectID: project.id),
            PlanTask(title: "Second open", day: "2026-11-13", projectID: project.id),
            PlanTask(title: "Other", day: nil),
        ]
        let value = ProjectCardModel(project: project, tasks: tasks)
        XCTAssertEqual(value.open, 2)
        XCTAssertEqual(value.done, 1)
        XCTAssertEqual(value.progress, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(value.next?.title, "First open")
    }

    func testEmptyProjectHasZeroProgressAndNoNextTask() {
        let value = ProjectCardModel(project: TaskProject(name: "Empty"), tasks: [])
        XCTAssertEqual(value.open, 0)
        XCTAssertEqual(value.done, 0)
        XCTAssertEqual(value.progress, 0)
        XCTAssertNil(value.next)
    }

    func testSurfaceIsStableAcrossRenameAndTaskChanges() {
        let project = TaskProject(id: UUID(uuidString: "00000000-0000-4000-8000-000000000300")!, name: "Work")
        var renamed = project
        renamed.name = "Notes"
        XCTAssertEqual(ProjectCardModel(project: project, tasks: []).surface, .butter)
        XCTAssertEqual(
            ProjectCardModel(project: renamed, tasks: []).surface,
            ProjectCardModel(project: project, tasks: []).surface)
    }
}
