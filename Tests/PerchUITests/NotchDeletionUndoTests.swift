import Foundation
import PlannerCore
import XCTest
@testable import PerchUI

final class NotchDeletionUndoTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDeletionOfferRejectsANewerPersistedAgentChangeBeforeObservation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        let local = PlannerCommandPipeline(file: file, clock: ClosurePlannerClock { self.now })
        let external = PlannerCommandPipeline(file: file, clock: ClosurePlannerClock { self.now })
        let task = try local.perform(origin: .user) {
            try $0.addTasks(["Call the bank"], on: .day($0.today), literal: true)[0]
        }.value
        let deleted = try local.perform(origin: .user) { try $0.delete(task.id, on: .day($0.today)) }
        let offer = NotchDeletionUndo(after: deleted.state, taskIDs: [task.id])
        XCTAssertTrue(offer.isValid(in: deleted.state))
        let added = try external.perform(origin: .background) { commands in
            let before = commands.planner
            let task = try commands.addTasks(
                ["New agent task"], on: .day(commands.today), literal: true, agentID: "claude-code")[0]
            try commands.recordAgentChange(from: before, agentID: "claude-code", operation: "add_tasks", at: now)
            return task
        }.value
        let persisted = try file.load()
        XCTAssertTrue(offer.isValid(in: deleted.state), "The published snapshot has not observed the other process")
        XCTAssertFalse(offer.isValid(in: persisted), "Revalidate persisted ordering, not the published planner")
        XCTAssertEqual(persisted.tasks.map(\.id), [added.id])
        XCTAssertNil(persisted.tasks.first { $0.id == task.id })
        let change = try XCTUnwrap(persisted.agentActions.changes.last)
        XCTAssertNil(change.undoneAt)
        try external.undoAgentChange(change.id)
        XCTAssertFalse(
            offer.isValid(in: try file.load()), "An intervening agent change permanently supersedes the offer")
    }

    func testUnchangedDeletionAllowsBackgroundFocusAccountingButNotRestoredTasks() {
        let task = PlanTask(title: "Call the bank", day: "2027-01-15")
        var planner = Planner()
        let offer = NotchDeletionUndo(after: planner, taskIDs: [task.id])
        planner.focus = FocusSession(taskID: nil, limit: 300, now: now)
        XCTAssertTrue(offer.isValid(in: planner))
        planner.tasks = [task]
        XCTAssertFalse(offer.isValid(in: planner))
    }
}
