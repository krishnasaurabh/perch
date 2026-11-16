import Foundation
import PlannerCore
import XCTest

/// Filing uses the same locked edit transaction and conditional Undo as the task editor.
final class ProjectFilingTests: XCTestCase {
    func testFilingAndUnfilingPreserveTaskFieldsAndUndoRedo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = PlannerFile(url: root.appendingPathComponent("planner.json"))
        let now = Date(timeIntervalSince1970: 1_800_014_400)
        let clock = ClosurePlannerClock { now }
        let pipeline = PlannerCommandPipeline(file: file, clock: clock)
        let task = try pipeline.perform(origin: .user) { commands in
            try commands.addTasks(["Check the notes #Work"], literal: false)[0]
        }.value
        let projectID = try XCTUnwrap(task.projectID)
        try pipeline.perform(origin: .user) { try $0.updateTask(task.id) { $0.projectID = nil } }
        var saved = try file.snapshot()
        XCTAssertNil(saved.tasks[0].projectID)
        XCTAssertEqual(saved.tasks[0].title, task.title)
        XCTAssertEqual(saved.tasks[0].day, task.day)
        _ = try pipeline.undo()
        XCTAssertEqual(try file.snapshot().tasks[0].projectID, projectID)
        _ = try pipeline.redo()
        XCTAssertNil(try file.snapshot().tasks[0].projectID)
        try pipeline.perform(origin: .user) { try $0.updateTask(task.id) { $0.projectID = projectID } }
        saved = try file.snapshot()
        XCTAssertEqual(saved.tasks[0].projectID, projectID)
        XCTAssertEqual(saved.tasks[0].id, task.id)
        XCTAssertEqual(saved.tasks[0].focusedSeconds, task.focusedSeconds)
    }

    func testBatchFilingIsAtomicWhenAnyIdentityIsMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = PlannerFile(url: root.appendingPathComponent("planner.json"))
        let pipeline = PlannerCommandPipeline(file: file)
        let task = try pipeline.perform(origin: .user) { try $0.addTasks(["Read notes #Work"])[0] }.value
        let before = try file.snapshot()
        XCTAssertThrowsError(
            try pipeline.perform(origin: .user) { commands in
                for id in [task.id, UUID()] { try commands.updateTask(id) { $0.projectID = nil } }
            })
        XCTAssertEqual(try file.snapshot(), before)
    }
}
