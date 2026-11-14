import PlannerTestSupport
import XCTest
@testable import PlannerCore
@testable import PerchMCP

final class MCPServerTests: XCTestCase {
    var dir: URL!
    var server: MCPServer!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tools = AgentTools(
            file: PlannerFile(
                url: dir.appendingPathComponent("planner.json"), preferences: AgentContractPreferences.enabled()),
            now: { Fixture.now }, calendar: Fixture.calendar)
        server = MCPServer(tools: tools, version: "test")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func call(_ name: String, _ args: JSON = [:]) -> (String, Bool) {
        let r = server.handle([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(name), "arguments": args],
        ])!
        let content = r["result"]!["content"]!.array![0]["text"]!.string!
        return (content, r["result"]!["isError"]!.bool!)
    }

    func testInitializeNegotiatesVersion() {
        let r = server.handle([
            "jsonrpc": "2.0", "id": 0, "method": "initialize", "params": ["protocolVersion": "2025-03-26"],
        ])!
        XCTAssertEqual(r["result"]?["protocolVersion"]?.string, "2025-03-26")
        XCTAssertEqual(r["result"]?["serverInfo"]?["name"]?.string, "perch")
        XCTAssertNil(server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]))
    }

    func testToolsListHasEveryTool() {
        let r = server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])!
        let names = r["result"]!["tools"]!.array!.compactMap { $0["name"]?.string }
        XCTAssertEqual(
            Set(names),
            [
                "add_tasks", "list_tasks", "list_inbox", "list_overdue", "update_overdue", "get_task",
                "complete_task", "reopen_task", "rename_task", "delete_task",
                "move_task", "update_task", "snooze_reminder", "start_timer", "pause_timer", "resume_timer",
                "stop_timer",
                "read_notepad", "write_notepad", "get_insights", "list_projects",
                "list_parked_thoughts", "add_parked_thought", "promote_parked_thought",
            ])
    }

    func testAgentFlow() {
        var (text, err) = call(
            "add_tasks", ["titles": ["text dad tomorrow at 5pm !high #home", "finish the report", "gym"]])
        XCTAssertFalse(err); XCTAssertTrue(text.contains("Added 3 tasks"), text)
        (text, _) = call("list_tasks")
        XCTAssertTrue(text.contains("finish the report"));
        XCTAssertTrue(text.contains("Planned ahead: 2026-11-10 (1)"), text)
        (text, _) = call("list_tasks", ["date": "tomorrow"])
        XCTAssertTrue(text.contains("text dad") && text.contains("high priority") && text.contains("#Home"), text)
        (text, err) = call("start_timer", ["task": "gym", "minutes": 30])
        XCTAssertFalse(err); XCTAssertTrue(text.contains("30 minutes"), text)
        (text, _) = call("list_tasks")
        XCTAssertTrue(text.contains("Focus timer: running, 30:00 left, on gym"), text)
        (text, err) = call("complete_task", ["task": "gym"])
        XCTAssertFalse(err)
        (text, err) = call("stop_timer")
        XCTAssertTrue(err); XCTAssertEqual(text, "Start a focus session first.")
        (text, err) = call(
            "update_task",
            [
                "task": "finish the report", "steps": ["outline", "draft"], "done_steps": ["outline"],
                "remind_at": "in 20 minutes",
            ])
        XCTAssertFalse(err, text); XCTAssertTrue(text.contains("[x] outline") && text.contains("15:20"), text)
        (text, err) = call("write_notepad", ["text": "ideas: weekly review"])
        XCTAssertFalse(err)
        (text, _) = call("read_notepad")
        XCTAssertTrue(text.contains("ideas: weekly review"))
        (text, _) = call("list_projects")
        XCTAssertEqual(text, "#Home: 1 open")
        (text, _) = call("get_insights")
        XCTAssertTrue(text.contains("Today: 1/2 tasks done"), text)
    }

    func testErrorsAreToolErrorsNotProtocolErrors() {
        let (text, err) = call("complete_task", ["task": "nope"])
        XCTAssertTrue(err); XCTAssertTrue(text.contains("No task found for \"nope\""), text)
        let r = server.handle(["jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": ["name": "rm_rf"]])!
        XCTAssertEqual(r["error"]?["code"]?.int, -32602)
        let m = server.handle(["jsonrpc": "2.0", "id": 9, "method": "bogus"])!
        XCTAssertEqual(m["error"]?["code"]?.int, -32601)
    }

    func testMinuteBoundsAndNumericStringCompatibility() throws {
        _ = call("add_tasks", ["titles": ["bounds probe"]])
        let file = PlannerFile(url: dir.appendingPathComponent("planner.json"))
        for value: JSON in [1, 720, "1", "720"] {
            let (text, error) = call("start_timer", ["minutes": value])
            XCTAssertFalse(error, text)
            XCTAssertEqual(try file.load().focus?.limit, Double(value.int!) * 60)
            let (updated, updateError) = call("update_task", ["task": "bounds probe", "minutes": value])
            XCTAssertFalse(updateError, updated)
            XCTAssertEqual(try file.load().tasks.first?.minutes, value.int)
        }
        let (_, clearError) = call("update_task", ["task": "bounds probe", "minutes": 0])
        XCTAssertFalse(clearError)
        XCTAssertNil(try file.load().tasks.first?.minutes)
        let (_, defaultError) = call("snooze_reminder", ["task": "bounds probe"])
        XCTAssertFalse(defaultError)
        XCTAssertEqual(try file.load().tasks.first?.remindAt, Fixture.now.addingTimeInterval(5 * 60))
        for value: JSON in [1, 1440, "1440"] {
            // Restore today's schedule after a full-day snooze.
            let task = try XCTUnwrap(file.load().tasks.first)
            if task.day != DayKey(Fixture.now, calendar: Fixture.calendar) {
                _ = call("move_task", ["task": .string(task.id.uuidString), "from": "tomorrow", "to": "today"])
            }
            let (text, error) = call("snooze_reminder", ["task": "bounds probe", "minutes": value])
            XCTAssertFalse(error, text)
            XCTAssertEqual(
                try file.load().tasks.first?.remindAt, Fixture.now.addingTimeInterval(Double(value.int!) * 60))
        }
        for name in ["start_timer", "snooze_reminder"] {
            let (_, error) = call(name, ["task": "bounds probe", "minutes": 0])
            XCTAssertTrue(error)
        }
        let tools = try XCTUnwrap(server.handle(["id": 1, "method": "tools/list"])?["result"]?["tools"]?.array)
        for (name, lower, upper) in [("start_timer", 1, 720), ("update_task", 0, 720), ("snooze_reminder", 1, 1440)] {
            let minutes = tools.first { $0["name"]?.string == name }?["inputSchema"]?["properties"]?["minutes"]
            XCTAssertEqual(minutes?["minimum"]?.int, lower)
            XCTAssertEqual(minutes?["maximum"]?.int, upper)
        }
    }

    func testNonJSONNumbersReturnParseErrorsWithoutStoppingStdio() throws {
        let lines =
            ["NaN", "Infinity", "-Infinity", "1e999"].map {
                "{\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"start_timer\",\"arguments\":{\"minutes\":\($0)}}}"
            } + [#"{"id":2,"method":"ping"}"#]
        let input = Pipe(), output = Pipe()
        input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        input.fileHandleForWriting.closeFile()
        server.runStdio(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        output.fileHandleForWriting.closeFile()
        let replies = try String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map { try JSON.parse(Data($0.utf8)) }
        XCTAssertEqual(replies.count, 5)
        for reply in replies.prefix(4) {
            XCTAssertEqual(reply["error"]?["code"]?.int, -32700)
            XCTAssertEqual(reply["id"], .null)
        }
        XCTAssertEqual(replies.last?["id"]?.int, 2)
        XCTAssertEqual(replies.last?["result"], [:])
    }

    func testStdioLoop() throws {
        let inPipe = Pipe(), outPipe = Pipe()
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add_tasks","arguments":{"titles":["x"]}}}"#,
            "garbage",
        ]
        inPipe.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        inPipe.fileHandleForWriting.closeFile()
        server.runStdio(input: inPipe.fileHandleForReading, output: outPipe.fileHandleForWriting)
        outPipe.fileHandleForWriting.closeFile()
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(out.count, 3, out.joined(separator: "\n"))
        XCTAssertTrue(out[1].contains("Added 1 task"))
        XCTAssertTrue(out[2].contains("-32700"))
    }
}
