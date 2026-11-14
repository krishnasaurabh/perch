import Foundation
import PlannerTestSupport
import XCTest
@testable import PlannerCore

final class PendingAgentActionsTests: XCTestCase {
    private func fixture() -> (URL, PlannerFile, PlannerCommandPipeline) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        let pipeline = PlannerCommandPipeline(
            file: file, clock: ClosurePlannerClock { Fixture.now }, calendar: Fixture.calendar)
        return (directory, file, pipeline)
    }

    private func addAgentTask(_ pipeline: PlannerCommandPipeline, title: String = "Write") throws -> UUID {
        try pipeline.perform(origin: .background) { commands in
            let before = commands.planner
            let task = try commands.addTasks([title], literal: true, agentID: "test-agent")[0]
            try commands.recordAgentChange(from: before, agentID: "test-agent", operation: "add_tasks", at: Fixture.now)
            return task.id
        }.value
    }

    func testLegacyDecodeDefaultsAndJournalRoundTrip() throws {
        let old = try PlannerFile.decodeDocument(Data("{\"version\":1}".utf8))
        XCTAssertEqual(old.agentActions, AgentActionLedger())
        let (directory, file, pipeline) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try addAgentTask(pipeline)
        let saved = try file.load()
        XCTAssertEqual(try PlannerFile.decodeDocument(Data(contentsOf: file.url)).agentActions, saved.agentActions)
        XCTAssertEqual(
            try PlannerFile.decoder.decode(Planner.self, from: PlannerFile.encoder.encode(saved)).agentActions,
            saved.agentActions)
    }

    func testReadOnlyCommandsCannotCreateOrUndoAgentActions() throws {
        let (directory, _, pipeline) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try addAgentTask(pipeline)
        XCTAssertThrowsError(
            try pipeline.inspect { try $0.requestAgentDeletion(id, agentID: "test-agent", at: Fixture.now) })
        XCTAssertThrowsError(try pipeline.inspect { try $0.expireAgentActions(at: Fixture.now) })
        XCTAssertThrowsError(
            try pipeline.inspect {
                try $0.recordAgentChange(
                    from: Planner(), agentID: "test-agent", operation: "add_tasks", at: Fixture.now)
            })
    }

    func testFailedTransactionDoesNotSaveTaskOrEvent() throws {
        let (directory, file, pipeline) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try file.save(Planner())
        let bytes = try Data(contentsOf: file.url)
        XCTAssertThrowsError(
            try pipeline.perform(origin: .background) { commands in
                let before = commands.planner
                _ = try commands.addTasks(["Write"], literal: true)
                try commands.recordAgentChange(
                    from: before, agentID: "test-agent", operation: "add_tasks", at: Fixture.now)
                throw PlannerError("Synthetic failure.")
            })
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
    }

    func testFailedDiskWriteDoesNotPublishPartialEventOrUndo() throws {
        let (directory, file, pipeline) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try addAgentTask(pipeline)
        let bytes = try Data(contentsOf: file.url)
        var io = PlannerFile.IO()
        io.write = { data, url in
            if url.lastPathComponent == "planner.json" { throw PlannerError("Synthetic write failure.") }
            try data.write(to: url, options: .atomic)
        }
        let failing = PlannerCommandPipeline(
            file: PlannerFile(url: file.url, io: io, preferences: MemoryPlannerPreferences()))
        XCTAssertThrowsError(try failing.undoAgentChange(try XCTUnwrap(file.load().agentActions.changes.last).id))
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        XCTAssertEqual(try file.load().tasks.first?.id, id)
        XCTAssertTrue(try file.load().agentActions.canUndo)
    }

    func testTimeoutAndRepeatedAnswersAreSafeAtBoundary() throws {
        let (directory, file, pipeline) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try addAgentTask(pipeline)
        let action = try pipeline.perform(origin: .background) {
            try $0.requestAgentDeletion(id, agentID: "test-agent", at: Fixture.now)
        }.value
        try pipeline.perform(origin: .background) {
            try $0.resolveAgentAction(action.id, decision: .keep, at: action.expiresAt)
        }
        XCTAssertEqual(try file.load().tasks.first?.id, id)
        XCTAssertEqual(try file.load().agentActions.events.last?.kind, .expired)
        let bytes = try Data(contentsOf: file.url)
        try pipeline.resolveAgentAction(action.id, decision: .keep)
        try pipeline.resolveAgentAction(action.id, decision: .undo)
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
    }

    func testDeletedTaskRestoresItsPositionAndAttribution() throws {
        let (directory, file, pipeline) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tasks = try pipeline.perform(origin: .background) {
            try $0.addTasks(["First", "Middle", "Last"], literal: true, agentID: "creator")
        }.value
        let action = try pipeline.perform(origin: .background) {
            try $0.requestAgentDeletion(tasks[1].id, agentID: "test-agent", at: Fixture.now)
        }.value
        try pipeline.resolveAgentAction(action.id, decision: .keep)
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().tasks.map(\.title), ["First", "Middle", "Last"])
        XCTAssertEqual(try file.load().tasks[1].agentID, "creator")
    }

    func testAgentUndoDoesNotReplaceLaterTaskEdits() throws {
        let (directory, file, pipeline) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try addAgentTask(pipeline)
        try pipeline.perform(origin: .user) { try $0.rename(id, on: .day($0.today), to: "Person") }
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().tasks.first?.title, "Write")
        _ = try pipeline.undo()
        XCTAssertTrue(try file.load().tasks.isEmpty)
    }

    func testTimerChangesCanBeUndoneWithoutDoubleCountingTime() throws {
        final class Clock { var now = Fixture.now }
        let clock = Clock()
        let (directory, file, _) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = PlannerCommandPipeline(
            file: file, clock: ClosurePlannerClock { clock.now }, calendar: Fixture.calendar)
        let id = try pipeline.perform(origin: .background) { try $0.addTasks(["Write"], literal: true)[0].id }.value
        func agent(_ operation: String, _ body: (PlannerCommands) throws -> Void) throws {
            try pipeline.perform(origin: .background) { commands in
                let before = commands.planner
                try body(commands)
                try commands.recordAgentChange(from: before, agentID: "test-agent", operation: operation, at: clock.now)
            }
        }
        try agent("start_timer") { _ = try $0.startTimer(task: id, minutes: 25) }
        clock.now = clock.now.addingTimeInterval(30)
        try agent("pause_timer") { try $0.pauseTimer() }
        clock.now = clock.now.addingTimeInterval(10)
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().focus?.state, .running)
        XCTAssertEqual(try file.load().focus?.elapsed(at: clock.now), 30)
        clock.now = clock.now.addingTimeInterval(20)
        try pipeline.perform(origin: .background) { _ = try $0.checkpointFocus() }
        XCTAssertEqual(try file.load().tasks[0].focusedSeconds, 50)
        _ = try pipeline.undo()
        XCTAssertNil(try file.load().focus)
        XCTAssertNil(try file.load().tasks[0].minutes)
        XCTAssertEqual(try file.load().tasks[0].focusedSeconds, 50)
        XCTAssertEqual(try file.load().focusSegments.reduce(0) { $0 + $1.seconds }, 50)
    }

    func testStopAndResumeHavePersistentUndoRecords() throws {
        let (directory, file, pipeline) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try pipeline.perform(origin: .background) {
            _ = try $0.startTimer(task: nil, minutes: 25); try $0.pauseTimer()
        }
        for operation in ["resume_timer", "stop_timer"] {
            try pipeline.perform(origin: .background) { commands in
                let before = commands.planner
                if operation == "resume_timer" { try commands.resumeTimer() } else { try commands.stopTimer() }
                try commands.recordAgentChange(
                    from: before, agentID: "test-agent", operation: operation, at: Fixture.now)
            }
            XCTAssertTrue(pipeline.canUndo)
            _ = try pipeline.undo()
            XCTAssertEqual(try file.load().focus?.state, .paused)
        }
    }

    func testEventStreamReadsPersistedCrossProcessChange() async throws {
        let (directory, file, pipeline) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try addAgentTask(pipeline)
        let event = try XCTUnwrap(file.load().agentActions.events.last)
        let otherProcess = PlannerFile(url: file.url, preferences: MemoryPlannerPreferences())
        var iterator = AgentActionEvents.stream(file: otherProcess, after: event.sequence - 1).makeAsyncIterator()
        let observed = try await iterator.next()
        XCTAssertEqual(observed, event)
    }
}
