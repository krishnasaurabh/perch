import Foundation
import PerchUI
import PlannerCore
import XCTest
@testable import PerchApp

final class NotchDeletionUndoCoordinatorTests: XCTestCase {
    @MainActor
    func testDeletionOfferRejectsAnAgentWriteBeforeWatcherReload() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let deletion = try XCTUnwrap(fixture.strips.currentActivity)
        XCTAssertEqual(deletion.stripKind, .undo)
        let added = try fixture.addExternally()
        XCTAssertFalse(fixture.store.planner.tasks.contains { $0.id == added.id })
        XCTAssertFalse(fixture.strips.answer(.undo, activity: deletion))
        try fixture.assertPersisted(agentTask: added)
        XCTAssertEqual(fixture.strips.currentActivity?.stripKind, .agentChange)
        XCTAssertTrue(fixture.strips.answer(.keep, activity: try XCTUnwrap(fixture.strips.currentActivity)))
        XCTAssertNil(fixture.strips.currentActivity)
        XCTAssertFalse(fixture.strips.answer(.undo, activity: deletion))
        try fixture.assertPersisted(agentTask: added)
    }

    @MainActor
    func testObservedAgentKeepAndTimeoutCannotRevealTheOldDeletionOffer() async throws {
        for keep in [true, false] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let deletion = try XCTUnwrap(fixture.strips.currentActivity)
            let added = try fixture.addExternally()
            fixture.store.reloadFromDisk(external: true)
            fixture.strips.refresh()
            let agent = try XCTUnwrap(fixture.strips.currentActivity)
            XCTAssertEqual(agent.stripKind, .agentChange)
            if keep {
                XCTAssertTrue(fixture.strips.answer(.keep, activity: agent))
            } else {
                fixture.now.addTimeInterval(10)
                fixture.strips.refresh()
            }
            XCTAssertNil(fixture.strips.currentActivity)
            XCTAssertFalse(fixture.strips.answer(.undo, activity: deletion))
            try fixture.assertPersisted(agentTask: added)
        }
    }

    @MainActor
    func testUnchangedDeletionUndoRestoresItsExactTaskAndCommandRedo() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let deletion = try XCTUnwrap(fixture.strips.currentActivity)
        XCTAssertTrue(fixture.strips.answer(.undo, activity: deletion))
        XCTAssertEqual(try fixture.file.load().tasks, fixture.originalTasks)
        XCTAssertTrue(fixture.store.canRedo)
        fixture.store.redo()
        XCTAssertEqual(try fixture.file.load().tasks.map(\.id), [fixture.originalTasks[1].id])
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let file: PlannerFile
        let store: PlannerStore
        let model: NotchModel
        let strips: NotchStrips
        let originalTasks: [PlanTask]
        private let clock = Time()
        var now: Date {
            get { clock.now }
            set { clock.now = newValue }
        }

        init() throws {
            let time = clock
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            file = PlannerFile(
                url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
            store = PlannerStore(file: file, now: { time.now }, watching: false)
            model = NotchModel()
            strips = NotchStrips(store: store, model: model, now: { time.now })
            model.strips = strips
            originalTasks = try XCTUnwrap(
                store.addTasks(["Call the bank", "Kept task"], on: .day(store.today), literal: true))
            store.apply { try $0.delete(originalTasks[0].id, on: .day($0.today)) }
            strips.refresh()
        }

        private final class Time {
            var now = Date(timeIntervalSince1970: 1_800_000_000)
        }

        func addExternally() throws -> PlanTask {
            let pipeline = PlannerCommandPipeline(file: file, clock: ClosurePlannerClock { self.now })
            return try pipeline.perform(origin: .background) { commands in
                let before = commands.planner
                let task = try commands.addTasks(
                    ["New agent task"], on: .day(commands.today), literal: true, agentID: "claude-code")[0]
                try commands.recordAgentChange(from: before, agentID: "claude-code", operation: "add_tasks", at: now)
                return task
            }.value
        }

        func assertPersisted(agentTask: PlanTask, file: StaticString = #filePath, line: UInt = #line) throws {
            let persisted = try self.file.load()
            XCTAssertEqual(Set(persisted.tasks.map(\.id)), [originalTasks[1].id, agentTask.id], file: file, line: line)
            XCTAssertFalse(persisted.tasks.contains { $0.id == originalTasks[0].id }, file: file, line: line)
            XCTAssertEqual(persisted.tasks.first { $0.id == agentTask.id }, agentTask, file: file, line: line)
            XCTAssertNil(persisted.agentActions.changes.last?.undoneAt, file: file, line: line)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }
}
