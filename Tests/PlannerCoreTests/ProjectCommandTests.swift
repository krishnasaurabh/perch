import Foundation
import XCTest
@testable import PlannerCore

final class ProjectCommandTests: XCTestCase {
    private var directory: URL!
    private var file: PlannerFile!
    private var pipeline: PlannerCommandPipeline!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        pipeline = PlannerCommandPipeline(
            file: file, clock: ClosurePlannerClock { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testCreateProjectTrimsNameAndCreatesNoTask() throws {
        let result = try pipeline.execute(.createProject("  Release Plan\n"), origin: .user)

        let project = try XCTUnwrap(result.value.projects.single)
        XCTAssertEqual(project.name, "Release Plan")
        XCTAssertEqual(result.state.projects, [project])
        XCTAssertTrue(result.state.tasks.isEmpty)
        XCTAssertEqual(result.state, try file.load())
    }

    func testPlannerCommandsCreateAndRenameProject() throws {
        let created = try pipeline.perform(origin: .user) { commands in
            try commands.createProject("  Home Admin  ")
        }.value
        let renamed = try pipeline.perform(origin: .user) { commands in
            try commands.renameProject(created.id, to: "  Household Admin  ")
        }.value

        XCTAssertEqual(created.id, renamed.id)
        XCTAssertEqual(created.colorHex, renamed.colorHex)
        XCTAssertEqual(renamed.name, "Household Admin")
        XCTAssertEqual(try file.load().projects, [renamed])
    }

    func testCreateProjectUndoRedoRestoresSameProjectID() throws {
        let created = try pipeline.execute(.createProject("Release Plan"), origin: .user)
        let afterCreate = created.state

        _ = try pipeline.undo()
        XCTAssertEqual(try file.load(), created.before)
        XCTAssertTrue(pipeline.canRedo)
        _ = try pipeline.redo()

        XCTAssertEqual(try file.load(), afterCreate)
        XCTAssertEqual(try file.load().projects.map(\.id), created.value.projects.map(\.id))
    }

    func testRenameProjectPreservesIdentityColorAndTaskAssociationsThroughUndoRedo() throws {
        let project = TaskProject(name: "Release Plan", colorHex: "#123456")
        let other = TaskProject(name: "Personal")
        let task = PlanTask(
            title: "Publish", day: "2027-01-15", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            projectID: project.id)
        let otherTask = PlanTask(
            title: "Shop", day: "2027-01-15", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            projectID: other.id)
        var planner = Planner()
        planner.projects = [project, other]
        planner.tasks = [task, otherTask]
        try file.save(planner)

        let renamed = try pipeline.execute(.renameProject(project.id, "  Launch Plan  "), origin: .user)
        let afterRename = renamed.state
        XCTAssertEqual(afterRename.projects.first?.id, project.id)
        XCTAssertEqual(afterRename.projects.first?.name, "Launch Plan")
        XCTAssertEqual(afterRename.projects.first?.colorHex, project.colorHex)
        XCTAssertEqual(afterRename.tasks, planner.tasks)

        _ = try pipeline.undo()
        XCTAssertEqual(try file.load(), planner)
        _ = try pipeline.redo()
        XCTAssertEqual(try file.load(), afterRename)
    }

    func testRenameProjectAllowsUnchangedNameAndCaseOnlyChange() throws {
        let project = TaskProject(name: "Release Plan")
        var planner = Planner()
        planner.projects = [project]
        try file.save(planner)

        let unchanged = try pipeline.execute(.renameProject(project.id, "  Release Plan\n"), origin: .user)
        XCTAssertEqual(unchanged.state, planner)
        XCTAssertEqual(try file.load(), planner)
        XCTAssertFalse(pipeline.canUndo)

        _ = try pipeline.execute(.renameProject(project.id, "release plan"), origin: .user)
        XCTAssertEqual(try file.load().projects.first?.name, "release plan")
        XCTAssertTrue(pipeline.canUndo)
    }

    func testInvalidProjectCommandsDoNotMutateStateOrHistory() throws {
        let project = TaskProject(name: "Work")
        let other = TaskProject(name: "Personal")
        let task = PlanTask(
            title: "Publish", day: "2027-01-15", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            projectID: project.id)
        var planner = Planner()
        planner.projects = [project, other]
        planner.tasks = [task]
        try file.save(planner)
        _ = try pipeline.execute(.createProject("Third"), origin: .user)
        let before = try file.load()
        let bytes = try Data(contentsOf: file.url)
        XCTAssertTrue(pipeline.canUndo)
        XCTAssertFalse(pipeline.canRedo)

        let actions: [PlannerAction] = [
            .createProject(" \n"),
            .createProject(" work "),
            .renameProject(project.id, "\n"),
            .renameProject(project.id, " personal "),
            .renameProject(UUID(), "Missing"),
            .deleteProject(UUID()),
        ]
        for action in actions {
            XCTAssertThrowsError(try pipeline.execute(action, origin: .user))
            XCTAssertEqual(try file.load(), before)
            XCTAssertEqual(try Data(contentsOf: file.url), bytes)
            XCTAssertTrue(pipeline.canUndo)
            XCTAssertFalse(pipeline.canRedo)
        }
    }

    func testDeleteProjectUndoRedoRestoresOrderAndTaskAssociations() throws {
        let project = TaskProject(name: "Work")
        let other = TaskProject(name: "Personal")
        let task = PlanTask(
            title: "Publish", day: "2027-01-15", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            projectID: project.id)
        let otherTask = PlanTask(
            title: "Shop", day: "2027-01-15", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            projectID: other.id)
        var planner = Planner()
        planner.projects = [project, other]
        planner.tasks = [task, otherTask]
        try file.save(planner)

        let deleted = try pipeline.execute(.deleteProject(project.id), origin: .user).state
        XCTAssertEqual(deleted.projects, [other])
        XCTAssertEqual(deleted.tasks.map(\.id), planner.tasks.map(\.id))
        XCTAssertNil(deleted.tasks[0].projectID)
        XCTAssertEqual(deleted.tasks[1].projectID, other.id)

        _ = try pipeline.undo()
        XCTAssertEqual(try file.load(), planner)
        _ = try pipeline.redo()
        XCTAssertEqual(try file.load(), deleted)
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
