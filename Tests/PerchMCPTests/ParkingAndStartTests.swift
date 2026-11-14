import Foundation
import PlannerTestSupport
import XCTest
@testable import PlannerCore
@testable import PerchMCP

final class ParkingAndStartTests: XCTestCase {
    private var directory: URL!
    private var file: PlannerFile!
    private var tools: AgentTools!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        tools = AgentTools(file: file, now: { Fixture.now }, calendar: Fixture.calendar)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testAddUpdateGetStartAndReminderRemainSeparate() throws {
        let added = try tools.callResult("add_tasks", ["titles": ["Write"], "literal": true, "start": "16:30"])
        let task = try XCTUnwrap(added.structuredContent["tasks"]?.array?.first)
        let id = try XCTUnwrap(task["id"]?.string)
        XCTAssertNotEqual(task["start"], .null)
        XCTAssertEqual(task["remind_at"], .null)
        XCTAssertEqual(Fixture.hm(try file.load().tasks[0].startAt), "2026-11-09 16:30")
        let update = try tools.callResult("update_task", ["task": .string(id), "start": "17:30", "remind_at": "18:00"])
        XCTAssertNotEqual(update.structuredContent["task"]?["start"], update.structuredContent["task"]?["remind_at"])
        XCTAssertEqual(Fixture.hm(try file.load().tasks[0].remindAt), "2026-11-09 18:00")
        let cleared = try tools.callResult("update_task", ["task": .string(id), "start": "none"])
        XCTAssertEqual(cleared.structuredContent["task"]?["start"], .null)
        let get = try tools.callResult("get_task", ["task": .string(id)])
        XCTAssertEqual(get.structuredContent["task"]?["start"], .null)
        XCTAssertNotEqual(get.structuredContent["task"]?["remind_at"], .null)
        let removed = try tools.callResult("delete_task", ["task": .string(id)])
        XCTAssertEqual(removed.structuredContent["task"]?["start"], .null)
    }

    func testParkingToolsAreDaylessLiteralAndAttributePromotedTask() throws {
        let added = try tools.callResult(
            "add_parked_thought", ["text": "Call tomorrow at 6pm"], agentID: "fixture-agent")
        let thought = try XCTUnwrap(added.structuredContent["thought"])
        let id = try XCTUnwrap(thought["id"]?.string)
        XCTAssertEqual(thought["text"]?.string, "Call tomorrow at 6pm")
        XCTAssertEqual(added.structuredContent["content_trust"]?.string, "untrusted")
        let bytes = try Data(contentsOf: file.url)
        let listed = try tools.callResult("list_parked_thoughts", [:])
        XCTAssertEqual(listed.structuredContent["thoughts"]?.array, [thought])
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        XCTAssertTrue(try file.load().tasks.isEmpty)
        let promoted = try tools.callResult(
            "promote_parked_thought", ["thought": .string(id), "date": "2026-11-11"], agentID: "fixture-agent")
        XCTAssertEqual(promoted.structuredContent["task"]?["day"]?.string, "2026-11-11")
        XCTAssertEqual(promoted.structuredContent["task"]?["title"]?.string, "Call tomorrow at 6pm")
        XCTAssertEqual(promoted.structuredContent["task"]?["start"], .null)
        XCTAssertEqual(try file.load().tasks[0].agentID, "fixture-agent")
        XCTAssertTrue(try file.load().parkedThoughts.isEmpty)
        XCTAssertThrowsError(try tools.callResult("promote_parked_thought", ["thought": .string(id)]))
    }

    func testPromotionDefaultsToTodayAndRejectsPastWithoutRemovingThought() throws {
        let thought = try tools.callResult("add_parked_thought", ["text": "Idea"]).structuredContent["thought"]!
        let id = thought["id"]!
        let before = try file.load()
        XCTAssertThrowsError(try tools.callResult("promote_parked_thought", ["thought": id, "date": "yesterday"]))
        XCTAssertEqual(try file.load(), before)
        let result = try tools.callResult("promote_parked_thought", ["thought": id])
        XCTAssertEqual(result.structuredContent["task"]?["day"]?.string, "2026-11-09")
    }

    func testMalformedNewArgumentsFailBeforeWrites() throws {
        try file.save(Planner())
        let before = try Data(contentsOf: file.url)
        for value: JSON in [.null, true, 4, [], [:]] {
            XCTAssertThrowsError(try tools.callResult("add_tasks", ["titles": ["Write"], "start": value]))
            XCTAssertThrowsError(try tools.callResult("update_task", ["task": "absent", "start": value]))
            XCTAssertThrowsError(try tools.callResult("add_parked_thought", ["text": value]))
            XCTAssertThrowsError(try tools.callResult("promote_parked_thought", ["thought": value]))
            XCTAssertEqual(try Data(contentsOf: file.url), before)
        }
        XCTAssertThrowsError(try tools.callResult("add_parked_thought", ["text": " "]))
        XCTAssertThrowsError(try tools.callResult("add_tasks", ["titles": ["Write", "Other"], "start": "bad"]))
        XCTAssertEqual(try Data(contentsOf: file.url), before)
    }

    func testSchemasAreAdditiveAndNewReadIsReadOnly() throws {
        XCTAssertEqual(AgentTools.definitions.count, 24)
        let definitions = Dictionary(uniqueKeysWithValues: AgentTools.definitions.map { ($0["name"]!.string!, $0) })
        XCTAssertEqual(definitions["list_parked_thoughts"]?["annotations"]?["readOnlyHint"]?.bool, true)
        XCTAssertNotNil(definitions["add_tasks"]?["inputSchema"]?["properties"]?["start"])
        XCTAssertNotNil(definitions["update_task"]?["inputSchema"]?["properties"]?["start"])
        for name in ["get_task", "update_task", "promote_parked_thought"] {
            XCTAssertNotNil(definitions[name]?["outputSchema"]?["properties"]?["task"]?["properties"]?["start"])
        }
    }
}
