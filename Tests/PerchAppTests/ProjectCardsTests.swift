import Foundation
import XCTest
import PlannerCore
@testable import PerchUI
@testable import PerchApp

final class ProjectCardsTests: XCTestCase {
    @MainActor
    func testTypedDropAdapterFilesAndUnfilesWithUndoAndRejectsMissingIdentitiesAtomically() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_014_400)
        let store = PlannerStore(
            file: PlannerFile(url: root.appendingPathComponent("planner.json")),
            now: { now }, watching: false)
        let result = try XCTUnwrap(store.send(.createProject("Notes")))
        let project = try XCTUnwrap(result.projects.first)
        let tasks = try XCTUnwrap(store.apply { try $0.addTasks(["Read the notes"], literal: true) })
        let task = try XCTUnwrap(tasks.first)
        let items = [TaskDragItem(taskID: task.id)]
        XCTAssertTrue(ProjectsList.file(items, in: project.id, store: store))
        XCTAssertEqual(store.planner.tasks.first?.projectID, project.id)
        store.undo()
        XCTAssertNil(store.planner.tasks.first?.projectID)
        store.redo()
        XCTAssertEqual(store.planner.tasks.first?.projectID, project.id)
        let before = store.planner
        XCTAssertFalse(ProjectsList.file(items + [TaskDragItem(taskID: UUID())], in: nil, store: store))
        XCTAssertEqual(store.planner, before)
        XCTAssertFalse(ProjectsList.file([], in: project.id, store: store))
        XCTAssertTrue(ProjectsList.file(items, in: nil, store: store))
        XCTAssertNil(try store.file.load().tasks.first?.projectID)
    }

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
