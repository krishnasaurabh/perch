import XCTest
@testable import PlannerCore

final class MCPServerTests: XCTestCase {
    var dir: URL!
    var server: MCPServer!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tools = AgentTools(file: PlannerFile(url: dir.appendingPathComponent("planner.json")),
                               now: { Fixture.now }, calendar: Fixture.calendar)
        server = MCPServer(tools: tools, version: "test")
    }

    func call(_ name: String, _ args: JSON = [:]) -> (String, Bool) {
        let r = server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(name), "arguments": args]])!
        let content = r["result"]!["content"]!.array![0]["text"]!.string!
        return (content, r["result"]!["isError"]!.bool!)
    }

    func testInitializeNegotiatesVersion() {
        let r = server.handle(["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": ["protocolVersion": "2025-03-26"]])!
        XCTAssertEqual(r["result"]?["protocolVersion"]?.string, "2025-03-26")
        XCTAssertEqual(r["result"]?["serverInfo"]?["name"]?.string, "perch")
        XCTAssertNil(server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]))
    }

    func testToolsListHasEveryTool() {
        let r = server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])!
        let names = r["result"]!["tools"]!.array!.compactMap { $0["name"]?.string }
        XCTAssertEqual(Set(names), [
            "add_tasks", "list_tasks", "get_task", "complete_task", "reopen_task", "rename_task", "delete_task",
            "move_task", "update_task", "snooze_reminder", "start_timer", "pause_timer", "resume_timer", "stop_timer",
            "read_notepad", "write_notepad", "get_insights", "list_projects",
        ])
    }

    func testAgentFlow() {
        var (text, err) = call("add_tasks", ["titles": ["text dad tomorrow at 5pm !high #home", "finish the report", "gym"]])
        XCTAssertFalse(err); XCTAssertTrue(text.contains("Added 3 tasks"), text)
        (text, _) = call("list_tasks")
        XCTAssertTrue(text.contains("Finish the report")); XCTAssertTrue(text.contains("Planned ahead: 2026-11-10 (1)"), text)
        (text, _) = call("list_tasks", ["date": "tomorrow"])
        XCTAssertTrue(text.contains("Text dad") && text.contains("high priority") && text.contains("#Home"), text)
        (text, err) = call("start_timer", ["task": "gym", "minutes": 30])
        XCTAssertFalse(err); XCTAssertTrue(text.contains("30 minutes"), text)
        (text, _) = call("list_tasks")
        XCTAssertTrue(text.contains("Focus timer: running, 30:00 left, on Gym"), text)
        (text, err) = call("complete_task", ["task": "gym"])
        XCTAssertFalse(err)
        (text, err) = call("stop_timer")
        XCTAssertTrue(err); XCTAssertEqual(text, "Start a focus session first.")
        (text, err) = call("update_task", ["task": "finish the report", "steps": ["outline", "draft"], "done_steps": ["outline"], "remind_at": "in 20 minutes"])
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
