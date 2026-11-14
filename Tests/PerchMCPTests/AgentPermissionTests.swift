import Foundation
import PlannerTestSupport
import XCTest
@testable import PerchMCP
@testable import PlannerCore

final class AgentPermissionTests: XCTestCase {
    private var directory: URL!
    private var file: PlannerFile!
    private var tools: AgentTools!
    private var pipeline: PlannerCommandPipeline!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        tools = AgentTools(file: file, now: { Fixture.now }, calendar: Fixture.calendar)
        pipeline = PlannerCommandPipeline(
            file: file, clock: ClosurePlannerClock { Fixture.now }, calendar: Fixture.calendar)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func seed() throws -> PlanTask {
        try pipeline.perform(origin: .background) { try $0.addTasks(["Write checklist"], literal: true)[0] }.value
    }

    func testDisabledWritesRefuseWithoutChangingDiskOrLedger() throws {
        let task = try seed()
        try pipeline.updatePreference(.agentsCanEditTasks(false), origin: .background)
        let before = try Data(contentsOf: file.url)
        let cases: [(String, JSON)] = [
            ("add_tasks", ["titles": ["Other"]]),
            ("rename_task", ["task": .string(task.id.uuidString), "title": "Other"]),
            ("update_task", ["task": .string(task.id.uuidString), "notes": "Other"]),
            ("complete_task", ["task": .string(task.id.uuidString)]),
            ("reopen_task", ["task": .string(task.id.uuidString)]),
            ("delete_task", ["task": .string(task.id.uuidString)]),
            ("move_task", ["task": .string(task.id.uuidString), "to": "tomorrow"]),
            ("snooze_reminder", ["task": .string(task.id.uuidString)]),
            ("update_overdue", ["action": "dismiss", "tasks": ["abcdef"]]),
            ("write_notepad", ["text": "Other"]),
            ("add_parked_thought", ["text": "Other"]),
            ("promote_parked_thought", ["thought": .string(UUID().uuidString)]),
        ]
        for (name, args) in cases {
            XCTAssertThrowsError(try tools.callResult(name, args, agentID: "test-agent")) { error in
                XCTAssertTrue(String(describing: error).contains("Add and edit tasks"), name)
            }
            XCTAssertEqual(try Data(contentsOf: file.url), before, name)
        }
        XCTAssertNoThrow(try tools.callResult("list_tasks", [:]))
        XCTAssertEqual(try Data(contentsOf: file.url), before)
    }

    func testTimeAndParkingAccessDefaultToOffAndCanBeEnabled() throws {
        _ = try seed()
        for name in ["start_timer", "pause_timer", "resume_timer", "stop_timer"] {
            XCTAssertThrowsError(try tools.callResult(name, [:])) { error in
                XCTAssertTrue(String(describing: error).contains("Start and stop time blocks"))
            }
        }
        for name in ["list_parked_thoughts", "read_notepad"] {
            XCTAssertThrowsError(try tools.callResult(name, [:])) { error in
                XCTAssertTrue(String(describing: error).contains("Read the parking lot"))
            }
        }
        try pipeline.updatePreference(.agentsCanControlTime(true), origin: .background)
        XCTAssertNoThrow(try tools.callResult("start_timer", [:], agentID: "test-agent"))
        try pipeline.updatePreference(.agentsCanReadParkingLot(true), origin: .background)
        XCTAssertNoThrow(try tools.callResult("list_parked_thoughts", [:]))
        XCTAssertNoThrow(try tools.callResult("read_notepad", [:]))
    }

    func testAnonymousCallsDoNotBypassPermissions() throws {
        try pipeline.updatePreference(.agentsCanEditTasks(false), origin: .background)
        XCTAssertThrowsError(try tools.callResult("add_tasks", ["titles": ["Other"]]))
    }

    func testTimePermissionDoesNotAllowChangingTaskLengthWhenEditsAreOff() throws {
        let task = try seed()
        try pipeline.updatePreference(.agentsCanControlTime(true), origin: .background)
        try pipeline.updatePreference(.agentsCanEditTasks(false), origin: .background)
        let bytes = try Data(contentsOf: file.url)
        XCTAssertThrowsError(try tools.callResult("start_timer", ["task": .string(task.id.uuidString), "minutes": 15]))
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        XCTAssertNoThrow(try tools.callResult("start_timer", ["task": .string(task.id.uuidString)]))
        XCTAssertNoThrow(try tools.callResult("stop_timer", [:]))
    }

    func testPendingDeleteKeepsTaskAndReportsWaitingAcrossRestart() throws {
        let task = try seed()
        let result = try tools.callResult("delete_task", ["task": .string(task.id.uuidString)], agentID: "test-agent")
        XCTAssertTrue(result.text.contains("waiting"))
        XCTAssertEqual(result.structuredContent["status"]?.string, "pending")
        XCTAssertEqual(result.structuredContent["task"]?["id"]?.string, task.id.uuidString.lowercased())
        XCTAssertEqual(try file.load().tasks, [task])
        let reopened = PlannerFile(url: file.url, preferences: MemoryPlannerPreferences())
        let action = try XCTUnwrap(reopened.load().agentActions.pending.first)
        XCTAssertEqual(action.agentID, "test-agent")
        XCTAssertEqual(action.task.id, task.id)
        XCTAssertEqual(action.expiresAt.timeIntervalSince(action.createdAt), 10)
    }

    func testDeleteKeepUndoAndTimeoutLifecycle() throws {
        let task = try seed()
        _ = try tools.callResult("delete_task", ["task": .string(task.id.uuidString)], agentID: "test-agent")
        var action = try XCTUnwrap(file.load().agentActions.pending.first)
        try pipeline.resolveAgentAction(action.id, decision: .undo)
        XCTAssertEqual(try file.load().tasks, [task])
        XCTAssertTrue(try file.load().agentActions.pending.isEmpty)
        _ = try tools.callResult("delete_task", ["task": .string(task.id.uuidString)], agentID: "test-agent")
        action = try XCTUnwrap(file.load().agentActions.pending.first)
        try pipeline.expireAgentActions(at: action.expiresAt)
        XCTAssertEqual(try file.load().tasks, [task])
        XCTAssertTrue(try file.load().agentActions.pending.isEmpty)
        _ = try tools.callResult("delete_task", ["task": .string(task.id.uuidString)], agentID: "test-agent")
        action = try XCTUnwrap(file.load().agentActions.pending.first)
        try pipeline.resolveAgentAction(action.id, decision: .keep)
        XCTAssertTrue(try file.load().tasks.isEmpty)
        let change = try XCTUnwrap(file.load().agentActions.changes.last)
        XCTAssertEqual(change.agentID, "test-agent")
        XCTAssertTrue(pipeline.canUndo)
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().tasks.map(\.id), [task.id])
    }

    func testDuplicatePendingDeleteIsIdempotentAndDoesNotExtendDeadline() throws {
        let task = try seed()
        _ = try tools.callResult("delete_task", ["task": .string(task.id.uuidString)], agentID: "test-agent")
        let before = try file.load().agentActions
        _ = try tools.callResult("delete_task", ["task": .string(task.id.uuidString)], agentID: "test-agent")
        XCTAssertEqual(try file.load().agentActions, before)
    }

    func testKeepRevalidatesPermissionAndEditedTask() throws {
        let task = try seed()
        _ = try tools.callResult("delete_task", ["task": .string(task.id.uuidString)])
        let action = try XCTUnwrap(file.load().agentActions.pending.first)
        try pipeline.perform(origin: .background) {
            try $0.rename(task.id, on: .day(DayKey("2026-11-09")), to: "Changed")
        }
        try pipeline.resolveAgentAction(action.id, decision: .keep)
        XCTAssertEqual(try file.load().tasks.first?.title, "Changed")
        XCTAssertTrue(try file.load().agentActions.pending.isEmpty)
        _ = try tools.callResult("delete_task", ["task": .string(task.id.uuidString)])
        let next = try XCTUnwrap(file.load().agentActions.pending.first)
        try pipeline.updatePreference(.agentsCanEditTasks(false), origin: .background)
        try pipeline.resolveAgentAction(next.id, decision: .keep)
        XCTAssertEqual(try file.load().tasks.first?.title, "Changed")
    }

    func testDirectDeleteWhenConfirmationIsOffIsStillUndoable() throws {
        let task = try seed()
        try pipeline.updatePreference(.confirmAgentDeletes(false), origin: .background)
        let result = try tools.callResult("delete_task", ["task": .string(task.id.uuidString)])
        XCTAssertEqual(result.text, "Deleted: Write checklist.")
        XCTAssertTrue(try file.load().agentActions.pending.isEmpty)
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().tasks.map(\.id), [task.id])
    }

    func testAttributionEventsAndConditionalUndoAcrossProcesses() throws {
        _ = try tools.callResult("add_tasks", ["titles": ["One", "Two"], "literal": true], agentID: "test-agent")
        let saved = try file.load()
        XCTAssertEqual(saved.tasks.map(\.agentID), ["test-agent", "test-agent"])
        let change = try XCTUnwrap(saved.agentActions.changes.last)
        XCTAssertEqual(change.tasks.map(\.title), ["One", "Two"])
        XCTAssertEqual(change.tasks.map(\.day), [DayKey("2026-11-09"), DayKey("2026-11-09")])
        XCTAssertEqual(saved.agentActions.events.last?.agentID, "test-agent")
        try pipeline.perform(origin: .background) {
            try $0.rename(saved.tasks[0].id, on: .day(DayKey("2026-11-09")), to: "Human edit")
        }
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().tasks.map(\.title), ["Human edit"])
    }

    func testLocalAndAgentUndoFollowActualOrder() throws {
        let task = try seed()
        try pipeline.perform(origin: .user) { try $0.rename(task.id, on: .day(DayKey("2026-11-09")), to: "Person") }
        _ = try tools.callResult("rename_task", ["task": .string(task.id.uuidString), "title": "Agent"])
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().tasks.first?.title, "Person")
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().tasks.first?.title, "Write checklist")
    }

    func testConcurrentClientsKeepEveryChangeAndEvent() throws {
        final class Failures: @unchecked Sendable {
            let lock = NSLock()
            var messages: [String] = []
            func append(_ error: Error) {
                lock.lock(); defer { lock.unlock() }; messages.append(String(describing: error))
            }
        }
        let failures = Failures()
        let location = file.url
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            let client = AgentTools(
                file: PlannerFile(url: location, preferences: MemoryPlannerPreferences()), now: { Fixture.now },
                calendar: Fixture.calendar)
            do {
                _ = try client.callResult(
                    "add_tasks", ["titles": [.string("Task \(index)")], "literal": true], agentID: "agent-\(index)")
            } catch { failures.append(error) }
        }
        XCTAssertEqual(failures.messages, [])
        let saved = try file.load()
        XCTAssertEqual(saved.tasks.count, 8)
        XCTAssertEqual(saved.agentActions.changes.count, 8)
        XCTAssertEqual(Set(saved.agentActions.changes.map(\.agentID)).count, 8)
        XCTAssertEqual(saved.agentActions.events.map(\.sequence), Array(1...8))
    }

    func testPendingDeleteWorksAcrossProtocolVersionsWithoutAnApprovalTool() throws {
        let task = try seed()
        for version in MCPServer.protocolVersions {
            let server = MCPServer(tools: tools, version: "test")
            _ = server.handle([
                "id": 1, "method": "initialize",
                "params": ["protocolVersion": .string(version), "clientInfo": ["name": .string(version)]],
            ])
            let response = server.handle([
                "id": 2, "method": "tools/call",
                "params": ["name": "delete_task", "arguments": ["task": .string(task.id.uuidString)]],
            ])
            XCTAssertEqual(response?["result"]?["isError"]?.bool, false)
            XCTAssertTrue(response?["result"]?["content"]?.array?.first?["text"]?.string?.contains("waiting") == true)
            XCTAssertEqual(response?["result"]?["structuredContent"] != nil, version == "2025-06-18")
            let denied = server.handle([
                "id": 3, "method": "tools/call", "params": ["name": "resolve_agent_action", "arguments": [:]],
            ])
            XCTAssertEqual(denied?["error"]?["code"]?.int, -32602)
        }
        XCTAssertEqual(try file.load().tasks.map(\.id), [task.id])
    }

    func testOverdueCompletionCannotStopTimeWithoutPermission() throws {
        var planner = Planner()
        let task = PlanTask(title: "Earlier", day: "2026-11-08", createdAt: Fixture.now)
        planner.tasks = [task]
        planner.focus = FocusSession(taskID: task.id, limit: 1500, now: Fixture.now)
        try file.save(planner)
        let bytes = try Data(contentsOf: file.url)
        XCTAssertThrowsError(
            try tools.callResult("update_overdue", ["action": "complete", "tasks": [.string(task.id.uuidString)]]))
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
    }

    func testServerUsesClientIdentityAndRefusalsAreToolErrors() throws {
        let server = MCPServer(tools: tools, version: "test")
        _ = server.handle(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "test-agent"]]])
        let response = server.handle([
            "id": 2, "method": "tools/call", "params": ["name": "add_tasks", "arguments": ["titles": ["One"]]],
        ])
        XCTAssertEqual(response?["result"]?["isError"]?.bool, false)
        XCTAssertEqual(try file.load().agentActions.changes.last?.agentID, "test-agent")
        let denied = server.handle(["id": 3, "method": "tools/call", "params": ["name": "start_timer"]])
        XCTAssertEqual(denied?["result"]?["isError"]?.bool, true)
    }
}
