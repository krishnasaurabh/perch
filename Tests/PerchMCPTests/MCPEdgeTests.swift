import PlannerTestSupport
import XCTest
@testable import PlannerCore
@testable import PerchMCP

/// JSON-RPC framing, batching, malformed input, huge payloads and every tool's error path.
final class MCPEdgeTests: XCTestCase {
    private var dir: URL!
    private var url: URL!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "perch-mcp-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("planner.json")
        let tools = AgentTools(file: PlannerFile(url: url), now: { Fixture.now }, calendar: Fixture.calendar)
        server = MCPServer(tools: tools, version: "edge")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: Helpers

    private func response(_ message: JSON) -> JSON? { server.handle(message) }

    private func call(_ name: String, _ args: JSON = [:]) -> (text: String, isError: Bool) {
        let message: JSON = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(name), "arguments": args],
        ]
        let r = response(message)!
        if let error = r["error"] {
            return (error["message"]?.string ?? "no message", true)
        }
        let result = r["result"]!
        return (result["content"]!.array![0]["text"]!.string!, result["isError"]!.bool!)
    }

    private func callMessage(_ name: String, arguments: JSON) -> JSON {
        ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(name), "arguments": arguments]]
    }

    private func errorCode(_ r: JSON?) -> Int? { r?["error"]?["code"]?.int }
    private func errorMessage(_ r: JSON?) -> String? { r?["error"]?["message"]?.string }

    @discardableResult
    private func runLines(_ lines: [String]) -> [String] {
        let inPipe = Pipe(), outPipe = Pipe()
        inPipe.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        inPipe.fileHandleForWriting.closeFile()
        server.runStdio(input: inPipe.fileHandleForReading, output: outPipe.fileHandleForWriting)
        outPipe.fileHandleForWriting.closeFile()
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func storedPlanner() throws -> Planner { try PlannerFile(url: url).load() }

    // MARK: Numeric safety and read-only storage

    func testIntegerDecodingRejectsNonFiniteFractionalAndOverflowValues() {
        let invalid: [Double] = [
            .nan, .infinity, -.infinity, 1e19, -1e19,
            Double(Int.max), Double(Int.min).nextDown, 0.5,
        ]
        for value in invalid { XCTAssertNil(JSON.number(value).int, "\(value)") }
        XCTAssertEqual(JSON.number(Double(Int.min)).int, Int.min)
        XCTAssertEqual(JSON.number(Double(Int.max).nextDown).int, Int(exactly: Double(Int.max).nextDown))
        XCTAssertEqual(JSON.number(720).int, 720)
        XCTAssertEqual(JSON.string("720").int, 720)
        XCTAssertNil(JSON.string("999999999999999999999999").int)
        XCTAssertNil(JSON.bool(true).int)
    }

    func testInvalidMinutesAreToolErrorsAndDoNotMutate() throws {
        _ = call("add_tasks", ["titles": ["numeric probe"]])
        let before = try Data(contentsOf: url)
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        var notifications = 0
        server.onChange = { notifications += 1 }
        let invalid: [JSON] = [
            .number(.nan), .number(.infinity), .number(-.infinity),
            .number(1e19), .number(-1e19), .number(Double(Int.max)),
            .number(Double(Int.min)), .number(1.5), -1,
            "NaN", "Infinity", "1e19", "1.5", .null, true, [], [:],
        ]
        for name in ["start_timer", "snooze_reminder", "update_task"] {
            let maximum = name == "snooze_reminder" ? 1440 : 720
            for value in invalid + [.number(Double(maximum + 1))] {
                let reply = response(
                    callMessage(
                        name, arguments: ["task": "numeric probe", "minutes": value, "notes": "must not persist"]))
                XCTAssertNil(reply?["error"], name)
                XCTAssertEqual(reply?["result"]?["isError"]?.bool, true, "\(name): \(value)")
                XCTAssertEqual(reply?["result"]?["content"]?.array?.first?["type"]?.string, "text")
                XCTAssertTrue(
                    reply?["result"]?["content"]?.array?.first?["text"]?.string?.contains("Invalid argument 'minutes'")
                        ?? false)
                XCTAssertEqual(try Data(contentsOf: url), before, name)
                XCTAssertEqual(
                    try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, modified)
                XCTAssertEqual(response(["id": 2, "method": "ping"])?["result"], [:])
            }
        }
        XCTAssertEqual(notifications, 0)
    }

    private var invalidTimerTasks: [JSON] {
        [
            0, 42, -1, .number(1.5), .number(1e19), .number(-1e19),
            .number(1e308), .number(-1e308), true, false, .null, [], ["task"],
            [:], ["id": "task"], "", " \t\r\n", "\u{00a0}",
        ]
    }

    private struct StorageEntry: Equatable {
        let data: Data?
        let modified: Date
    }

    private func storageSnapshot() throws -> [String: StorageEntry] {
        var result: [String: StorageEntry] = [:]
        func walk(_ entry: URL, _ key: String) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: entry.path)
            let isDirectory = attributes[.type] as? FileAttributeType == .typeDirectory
            result[key] = StorageEntry(
                data: isDirectory ? nil : try Data(contentsOf: entry),
                modified: try XCTUnwrap(attributes[.modificationDate] as? Date))
            if isDirectory {
                for child in try FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil) {
                    try walk(child, key + "/" + child.lastPathComponent)
                }
            }
        }
        try walk(dir, "")
        return result
    }

    func testInvalidTimerTaskReferencesLeaveActiveSessionAndStorageUnchanged() throws {
        XCTAssertFalse(call("add_tasks", ["titles": ["active focus task"]]).isError)
        XCTAssertFalse(call("start_timer", ["task": "active focus task", "minutes": 25]).isError)
        let active = try XCTUnwrap(storedPlanner().focus)
        let before = try storageSnapshot()
        XCTAssertTrue(before.keys.contains { $0.contains(".backups/") })
        var notifications = 0
        server.onChange = { notifications += 1 }
        for value in invalidTimerTasks {
            let reply = response(callMessage("start_timer", arguments: ["task": value, "minutes": 5]))
            XCTAssertNil(reply?["error"], "\(value)")
            XCTAssertEqual(reply?["result"]?["isError"]?.bool, true, "\(value)")
            XCTAssertEqual(reply?["result"]?["content"]?.array?.first?["type"]?.string, "text")
            XCTAssertTrue(
                reply?["result"]?["content"]?.array?.first?["text"]?.string?.contains("Invalid argument 'task'")
                    ?? false)
            XCTAssertEqual(try storageSnapshot(), before, "\(value)")
            XCTAssertEqual(try storedPlanner().focus, active)
            XCTAssertEqual(notifications, 0)
            XCTAssertEqual(response(["id": 2, "method": "ping"])?["result"], [:])
        }
        XCTAssertFalse(call("pause_timer").isError)
        XCTAssertEqual(notifications, 1, "a valid request still works after the errors")
    }

    func testInvalidTimerTaskReferencesDoNotCreateStorageOrRecoveryArtifacts() throws {
        var notifications = 0
        server.onChange = { notifications += 1 }
        for corrupt in [false, true] {
            if corrupt { try Data("{invalid".utf8).write(to: url) }
            let before = try storageSnapshot()
            for value in invalidTimerTasks {
                let result = call("start_timer", ["task": value, "minutes": 5])
                XCTAssertTrue(result.isError)
                XCTAssertTrue(result.text.contains("Invalid argument 'task'"), result.text)
                XCTAssertEqual(try storageSnapshot(), before, "validation must precede storage access")
            }
        }
        XCTAssertEqual(notifications, 0)
    }

    func testTimerTaskOmissionAndStringReferencesRemainSupported() throws {
        XCTAssertFalse(call("add_tasks", ["titles": ["valid focus task"]]).isError)
        let task = try XCTUnwrap(storedPlanner().tasks.first)
        for reference in [
            task.id.uuidString, String(task.id.uuidString.prefix(8)).lowercased(), task.title, "valid focus",
        ] {
            XCTAssertFalse(call("start_timer", ["task": .string(reference), "minutes": 5]).isError, reference)
            XCTAssertEqual(try storedPlanner().focus?.taskID, task.id)
            XCTAssertEqual(try storedPlanner().focus?.limit, 300)
        }
        XCTAssertFalse(call("start_timer", ["minutes": 10]).isError)
        XCTAssertNil(try storedPlanner().focus?.taskID)
        XCTAssertEqual(try storedPlanner().focus?.limit, 600)
        XCTAssertFalse(call("start_timer", ["task": .string(task.id.uuidString)]).isError)
        XCTAssertEqual(try storedPlanner().focus?.taskID, task.id)
    }

    func testInvalidTimerTasksInBatchAllowFollowingValidRequests() throws {
        XCTAssertFalse(call("add_tasks", ["titles": ["batch focus task"]]).isError)
        XCTAssertFalse(call("start_timer", ["task": "batch focus task", "minutes": 25]).isError)
        let before = try storageSnapshot()
        var notifications = 0
        server.onChange = { notifications += 1 }
        let batch = JSON.array(
            invalidTimerTasks.map {
                callMessage("start_timer", arguments: ["task": $0, "minutes": 5])
            } + [["id": 2, "method": "ping"]])
        let out = runLines([String(decoding: batch.data(), as: UTF8.self), #"{"id":3,"method":"ping"}"#])
        XCTAssertEqual(out.count, 2)
        let replies = try XCTUnwrap(JSON.parse(Data(out[0].utf8)).array)
        XCTAssertEqual(replies.count, invalidTimerTasks.count + 1)
        for reply in replies.dropLast() {
            XCTAssertNil(reply["error"])
            XCTAssertEqual(reply["result"]?["isError"]?.bool, true)
        }
        XCTAssertEqual(replies.last?["result"], [:])
        XCTAssertEqual(try JSON.parse(Data(out[1].utf8))["id"]?.int, 3)
        XCTAssertEqual(try storageSnapshot(), before)
        XCTAssertEqual(notifications, 0)
        let valid = runLines([
            #"{"id":4,"method":"tools/call","params":{"name":"start_timer","arguments":{"task":"batch focus task","minutes":5}}}"#
        ])
        XCTAssertEqual(try JSON.parse(Data(valid[0].utf8))["result"]?["isError"]?.bool, false)
        XCTAssertEqual(try storedPlanner().focus?.taskID, try storedPlanner().tasks.first?.id)
        XCTAssertEqual(try storedPlanner().focus?.limit, 300)
        XCTAssertEqual(notifications, 1)
    }

    func testNumericTaskReferencesRejectOverflowWithoutTrapping() {
        for name in [
            "get_task", "complete_task", "reopen_task", "rename_task", "delete_task", "move_task", "update_task",
            "snooze_reminder",
        ] {
            let reply = response(
                callMessage(
                    name, arguments: ["task": .number(1e19), "title": "replacement", "to": "inbox", "minutes": 5]))
            XCTAssertNil(reply?["error"], name)
            XCTAssertEqual(reply?["result"]?["isError"]?.bool, true, name)
            XCTAssertTrue(
                reply?["result"]?["content"]?.array?.first?["text"]?.string?.contains("Identify the task") ?? false,
                name)
        }
    }

    func testInvalidMinutesInBatchPreserveFollowingValidRequest() throws {
        let batch =
            #"[{"id":1,"method":"tools/call","params":{"name":"start_timer","arguments":{"minutes":1e19}}},{"id":2,"method":"tools/call","params":{"name":"start_timer","arguments":{"minutes":5}}},{"method":"notifications/initialized"},{"id":3,"method":"ping"}]"#
        let out = runLines([batch, #"{"id":4,"method":"ping"}"#])
        XCTAssertEqual(out.count, 2)
        let replies = try XCTUnwrap(JSON.parse(Data(out[0].utf8)).array)
        XCTAssertEqual(replies.map { $0["id"]?.int }, [1, 2, 3])
        XCTAssertEqual(replies[0]["result"]?["isError"]?.bool, true)
        XCTAssertEqual(replies[1]["result"]?["isError"]?.bool, false)
        XCTAssertEqual(replies[2]["result"], [:])
        XCTAssertEqual(try JSON.parse(Data(out[1].utf8))["id"]?.int, 4)
        XCTAssertEqual(try storedPlanner().focus?.limit, 300)
    }

    func testDeclaredReadOnlyToolsLeaveDirectoryUnchanged() throws {
        let names = Set(
            AgentTools.definitions.filter { $0["annotations"]?["readOnlyHint"]?.bool == true }.compactMap {
                $0["name"]?.string
            })
        XCTAssertEqual(
            names,
            [
                "get_task", "list_inbox", "list_overdue", "read_notepad", "get_insights", "list_projects",
                "list_parked_thoughts",
            ])
        func snapshot() throws -> [String: Data] {
            var result: [String: Data] = [:]
            func walk(_ base: URL, _ prefix: String) throws {
                let entries = try FileManager.default.contentsOfDirectory(
                    at: base, includingPropertiesForKeys: [.isDirectoryKey])
                for file in entries {
                    let key = prefix + file.lastPathComponent
                    if try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                        result[key] = Data("<directory>".utf8)
                        try walk(file, key + "/")
                        continue
                    }
                    result[key] = try Data(contentsOf: file)
                    let modified =
                        try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
                    result[key + ".mtime"] = Data(String(modified.timeIntervalSince1970).utf8)
                }
            }
            try walk(dir, "")
            return result
        }
        // Missing storage, valid repeat data, and corrupt storage all remain untouched.
        for state in ["missing", "valid", "corrupt"] {
            if state == "valid" {
                _ = call("add_tasks", ["titles": ["readonly probe every day"]])
                _ = call("write_notepad", ["text": "synthetic note"])
                try FileManager.default.removeItem(at: url.appendingPathExtension("lock"))
            } else if state == "corrupt" {
                try Data("{invalid".utf8).write(to: url)
            }
            let before = try snapshot()
            for name in names {
                let args: JSON = name == "get_task" ? ["task": "readonly probe"] : [:]
                let (text, error) = call(name, args)
                XCTAssertEqual(
                    error, state == "corrupt" || (state == "missing" && name == "get_task"), "\(name): \(text)")
                XCTAssertEqual(try snapshot(), before, "\(name) changed \(state) storage")
            }
        }
    }

    func testListTasksAnnotationMatchesRepeatMaterialization() throws {
        let definition = AgentTools.definitions.first { $0["name"]?.string == "list_tasks" }
        XCTAssertEqual(definition?["annotations"]?["readOnlyHint"]?.bool, false)
        _ = call("add_tasks", ["titles": ["repeat probe every day"]])
        let before = try Data(contentsOf: url)
        var notifications = 0
        server.onChange = { notifications += 1 }
        let (text, error) = call("list_tasks", ["date": "tomorrow"])
        XCTAssertFalse(error, text)
        XCTAssertTrue(text.contains("repeat probe"))
        XCTAssertNotEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try storedPlanner().tasks.count, 2)
        XCTAssertEqual(notifications, 1)
        let materialized = try Data(contentsOf: url)
        _ = call("list_tasks", ["date": "tomorrow"])
        XCTAssertEqual(try Data(contentsOf: url), materialized, "repeat ids remain stable")
    }

    // MARK: Protocol

    func testInitializeNegotiatesEverySupportedVersion() {
        for version in MCPServer.protocolVersions {
            let r = response([
                "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": .string(version)],
            ])!
            XCTAssertEqual(r["result"]?["protocolVersion"]?.string, version)
            XCTAssertEqual(r["result"]?["serverInfo"]?["name"]?.string, "perch")
            XCTAssertEqual(r["result"]?["serverInfo"]?["version"]?.string, "edge")
            XCTAssertEqual(r["result"]?["capabilities"]?["tools"]?["listChanged"]?.bool, false)
            XCTAssertTrue(r["result"]?["instructions"]?.string?.contains("list_tasks") ?? false)
        }
        let bogus = response([
            "jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "1999-01-01"],
        ])!
        XCTAssertEqual(bogus["result"]?["protocolVersion"]?.string, MCPServer.protocolVersions[0])
        let missing = response(["jsonrpc": "2.0", "id": 3, "method": "initialize"])!
        XCTAssertEqual(missing["result"]?["protocolVersion"]?.string, MCPServer.protocolVersions[0])
        let arrayParams = response(["jsonrpc": "2.0", "id": 4, "method": "initialize", "params": .array([])])!
        XCTAssertEqual(arrayParams["result"]?["protocolVersion"]?.string, MCPServer.protocolVersions[0])
    }

    func testPingAndEmptyListings() {
        XCTAssertEqual(response(["jsonrpc": "2.0", "id": 1, "method": "ping"])?["result"], .object([:]))
        XCTAssertEqual(response(["jsonrpc": "2.0", "id": "abc", "method": "ping"])?["id"]?.string, "abc")
        XCTAssertEqual(
            response(["jsonrpc": "2.0", "id": 2, "method": "resources/list"])?["result"]?["resources"], .array([]))
        XCTAssertEqual(
            response(["jsonrpc": "2.0", "id": 3, "method": "prompts/list"])?["result"]?["prompts"], .array([]))
    }

    func testProtocolErrors() {
        XCTAssertEqual(errorCode(response(["jsonrpc": "2.0", "id": 1])), -32600)
        XCTAssertEqual(errorCode(response(["jsonrpc": "2.0", "id": 2, "method": "bogus"])), -32601)
        XCTAssertTrue(
            errorMessage(response(["jsonrpc": "2.0", "id": 2, "method": "bogus"]))?.contains("bogus") ?? false)
        XCTAssertNil(response(["jsonrpc": "2.0", "method": "bogus"]), "unknown notifications are silent")
        XCTAssertNil(response(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        XCTAssertEqual(
            errorCode(response(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": .object([:])])), -32602)
        XCTAssertEqual(
            errorMessage(response(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": 42]])),
            "Missing tool name")
        XCTAssertEqual(
            errorMessage(response(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "rm_rf"]])),
            "Unknown tool: rm_rf")
        XCTAssertEqual(
            errorCode(response(["jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": .array([])])), -32602)
    }

    func testNullIdNotificationIsAnsweredAsARequest() {
        // JSON-RPC discourages an explicit null id; the server treats it as a request
        // because the key exists. Documented so a future change is a deliberate one.
        let r = response(["jsonrpc": "2.0", "id": .null, "method": "notifications/initialized"])
        XCTAssertEqual(errorCode(r), -32601)
        let ping = response(["jsonrpc": "2.0", "id": .null, "method": "ping"])
        XCTAssertEqual(ping?["result"], .object([:]))
        XCTAssertEqual(String(data: ping!.data(), encoding: .utf8)?.contains("\"id\":null"), true)
    }

    func testToolSchemasAreWellFormed() {
        let tools = AgentTools.definitions
        let names = tools.compactMap { $0["name"]?.string }
        XCTAssertEqual(names.count, 24)
        XCTAssertEqual(Set(names).count, 24)
        for tool in tools {
            let name = tool["name"]?.string ?? "?"
            XCTAssertFalse(tool["description"]?.string?.isEmpty ?? true, "\(name) has no description")
            XCTAssertEqual(tool["inputSchema"]?["type"]?.string, "object", name)
            XCTAssertEqual(tool["inputSchema"]?["additionalProperties"]?.bool, false, name)
            XCTAssertEqual(tool["outputSchema"]?["type"]?.string, "object", name)
            XCTAssertEqual(tool["outputSchema"]?["additionalProperties"]?.bool, false, name)
            XCTAssertEqual(tool["outputSchema"]?["properties"]?["content_trust"]?["const"]?.string, "untrusted", name)
            let props: [String: JSON]
            if case .object(let declared)? = tool["inputSchema"]?["properties"] {
                props = declared
            } else {
                props = [:]
            }
            let required = tool["inputSchema"]?["required"]?.array?.compactMap(\.string) ?? []
            for key in required {
                XCTAssertNotNil(props[key], "\(name) requires \(key) but does not declare it")
            }
            XCTAssertNotNil(tool["annotations"]?["readOnlyHint"]?.bool, "\(name) has no readOnlyHint")
        }
        let requiredByTool = Dictionary(
            uniqueKeysWithValues: tools.map {
                ($0["name"]!.string!, $0["inputSchema"]!["required"]!.array!.compactMap(\.string))
            })
        XCTAssertEqual(requiredByTool["add_tasks"], ["titles"])
        XCTAssertEqual(requiredByTool["list_inbox"], [])
        XCTAssertEqual(requiredByTool["list_overdue"], [])
        XCTAssertEqual(requiredByTool["update_overdue"], ["action", "tasks"])
        XCTAssertEqual(requiredByTool["get_task"], ["task"])
        XCTAssertEqual(requiredByTool["rename_task"], ["task", "title"])
        XCTAssertEqual(requiredByTool["move_task"], ["task", "to"])
        XCTAssertEqual(requiredByTool["write_notepad"], ["text"])
        XCTAssertEqual(requiredByTool["get_insights"], [])
    }

    func testReadOnlyToolsDoNotNotify() {
        var changes = 0
        server.onChange = { changes += 1 }
        _ = call("add_tasks", ["titles": ["probe task"]])
        XCTAssertEqual(changes, 1)

        _ = call("get_task", ["task": "probe task"])
        _ = call("list_inbox")
        _ = call("list_overdue")
        _ = call("read_notepad")
        _ = call("get_insights")
        _ = call("list_projects")
        XCTAssertEqual(changes, 1, "read-only tools must not ask the app to refresh")

        _ = call("complete_task", ["task": "ghost"])
        XCTAssertEqual(changes, 1, "a failing tool call must not notify")

        _ = call("complete_task", ["task": "probe task"])
        XCTAssertEqual(changes, 2)
        _ = call("list_tasks")
        XCTAssertEqual(changes, 3, "listing may persist repeat occurrences")
    }

    // MARK: Framing and batches

    func testMalformedJSONProducesParseErrorsAndSkipsBlankLines() {
        let out = runLines(["garbage", "{", #"{"jsonrpc":}"#, "1e999", "   ", #"{"a":}"#])
        XCTAssertEqual(out.count, 5, out.joined(separator: "\n"))
        for line in out {
            XCTAssertTrue(line.contains("-32700"), line)
            XCTAssertTrue(line.contains("\"id\":null"), line)
        }
    }

    func testBatchRequestsReturnOneArrayInOrder() {
        let batch =
            #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","id":2,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]"#
        let out = runLines([batch])
        XCTAssertEqual(out.count, 1)
        let reply = try! JSON.parse(Data(out[0].utf8))
        XCTAssertEqual(reply.array?.count, 2)
        XCTAssertEqual(reply.array?.map { $0["id"]?.int }, [1, 2])
        XCTAssertEqual(reply.array?.map { $0["result"] }, [.object([:]), .object([:])])
    }

    func testBatchKeepsPerItemErrors() {
        let batch =
            #"[{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rm_rf"}},{"jsonrpc":"2.0","id":2,"method":"bogus"}]"#
        let reply = try! JSON.parse(Data(runLines([batch])[0].utf8))
        XCTAssertEqual(reply.array?.count, 2)
        XCTAssertEqual(reply.array?[0]["error"]?["code"]?.int, -32602)
        XCTAssertEqual(reply.array?[1]["error"]?["code"]?.int, -32601)
    }

    func testNotificationOnlyBatchIsSilent() {
        XCTAssertTrue(
            runLines([#"[{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","method":"bogus"}]"#])
                .isEmpty)
    }

    func testHugeBatchIsHandled() {
        let count = 1_000
        let batch =
            "[" + (0..<count).map { #"{"jsonrpc":"2.0","id":\#($0),"method":"ping"}"# }.joined(separator: ",") + "]"
        let out = runLines([batch])
        XCTAssertEqual(out.count, 1)
        let reply = try! JSON.parse(Data(out[0].utf8))
        XCTAssertEqual(reply.array?.count, count)
        XCTAssertEqual(reply.array?.first?["id"]?.int, 0)
        XCTAssertEqual(reply.array?.last?["id"]?.int, count - 1)
    }

    func testNonObjectMessagesAndEmptyBatchGetInvalidRequest() {
        // JSON-RPC 2.0: a message that is not a Request object, and a batch with no
        // members, are both Invalid Request (-32600) answered with a null id.
        for msg: JSON in [.number(123), .string("hello"), .null, .bool(true), .array([.number(1)])] {
            let r = response(msg)
            XCTAssertEqual(r?["jsonrpc"]?.string, "2.0", "\(msg)")
            XCTAssertEqual(errorCode(r), -32600, "\(msg)")
            XCTAssertEqual(r?["id"], .null, "\(msg)")
        }
        // An empty batch is answered with one error object, not an array.
        let empty = response(.array([]))
        XCTAssertEqual(errorCode(empty), -32600)
        XCTAssertEqual(empty?["id"], .null)
        XCTAssertNil(empty?.array)

        // Repro from the report: printf '123\n[]\n' | perch-cli --mcp now answers both.
        let out = runLines(["123", "[]", #""hello""#])
        XCTAssertEqual(out.count, 3, out.joined(separator: "\n"))
        for line in out {
            let r = try! JSON.parse(Data(line.utf8))
            XCTAssertEqual(errorCode(r), -32600, line)
            XCTAssertEqual(r["id"], .null, line)
            XCTAssertNil(r.array, line)
        }

        // Inside a batch, a non-object member gets its own -32600 entry and the
        // valid members around it are still answered in order.
        let mixed = runLines([#"[123,{"jsonrpc":"2.0","id":7,"method":"ping"}]"#])
        XCTAssertEqual(mixed.count, 1)
        let batch = try! JSON.parse(Data(mixed[0].utf8)).array
        XCTAssertEqual(batch?.count, 2)
        XCTAssertEqual(errorCode(batch?[0]), -32600)
        XCTAssertEqual(batch?[0]["id"], .null)
        XCTAssertEqual(batch?[1]["id"]?.int, 7)
        XCTAssertEqual(batch?[1]["result"], .object([:]))
    }

    func testBUG_TabOnlyLineIsTreatedAsMalformedJSON() {
        // BUG: the stdio loop skips lines made only of spaces and CR, but a tab-only
        // line reaches the JSON parser and earns a Parse error. Harmless in practice,
        // but it is not an "invalid message" a client sent on purpose.
        // Repro: printf '\t\n' | perch-cli --mcp   (-32700 instead of silence)
        let out = runLines(["\t"])
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].contains("-32700"), out[0])
    }

    func testCRLFLineEndingsAreTolerated() {
        let out = runLines([#"{"jsonrpc":"2.0","id":7,"method":"ping"}"# + "\r"])
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].contains("\"id\":7"))
    }

    // MARK: Published schema boundaries

    func testNumericStringMinutesMatchPublishedStringSchemaAndRejectWithoutMutation() throws {
        let definition = try XCTUnwrap(AgentTools.definitions.first { $0["name"]?.string == "start_timer" })
        let choices = try XCTUnwrap(
            definition["inputSchema"]?["properties"]?["minutes"]?["anyOf"]?.array)
        let stringSchema = try XCTUnwrap(choices.first { $0["type"]?.string == "string" })
        let maximum = try XCTUnwrap(stringSchema["maxLength"]?.int)

        let exact = String(repeating: "0", count: maximum - 2) + "25"
        XCTAssertEqual(exact.unicodeScalars.count, maximum)
        let accepted = call("start_timer", ["minutes": .string(exact)])
        XCTAssertFalse(accepted.isError, accepted.text)
        XCTAssertEqual(try storedPlanner().focus?.limit, 1_500)

        let before = try storageSnapshot()
        let oversized = String(repeating: "0", count: maximum - 1) + "25"
        XCTAssertEqual(oversized.unicodeScalars.count, maximum + 1)
        XCTAssertEqual(JSON.string(oversized).int, 25)
        let rejected = call("start_timer", ["minutes": .string(oversized)])
        XCTAssertTrue(rejected.isError, rejected.text)
        XCTAssertTrue(rejected.text.contains("Invalid argument 'minutes'"), rejected.text)
        XCTAssertEqual(try storageSnapshot(), before)
    }

    func testTitleLengthMatchesPublishedUnicodeCodePointSchemaAndRejectsWithoutMutation() throws {
        let definition = try XCTUnwrap(AgentTools.definitions.first { $0["name"]?.string == "add_tasks" })
        let maximum = try XCTUnwrap(
            definition["inputSchema"]?["properties"]?["titles"]?["items"]?["maxLength"]?.int)
        let decomposedCharacter = "e\u{301}"
        XCTAssertEqual(decomposedCharacter.count, 1)
        XCTAssertEqual(decomposedCharacter.unicodeScalars.count, 2)

        let exact = String(repeating: decomposedCharacter, count: maximum / 2)
        XCTAssertEqual(exact.unicodeScalars.count, maximum)
        let accepted = call("add_tasks", ["titles": [.string(exact)], "literal": true])
        XCTAssertFalse(accepted.isError, accepted.text)
        XCTAssertEqual(try storedPlanner().tasks.map(\.title), [exact])

        let before = try storageSnapshot()
        let oversized = String(repeating: decomposedCharacter, count: maximum / 2 + 1)
        XCTAssertEqual(oversized.unicodeScalars.count, maximum + 2)
        let rejected = call("add_tasks", ["titles": [.string(oversized)], "literal": true])
        XCTAssertTrue(rejected.isError, rejected.text)
        XCTAssertTrue(rejected.text.contains("2000"), rejected.text)
        XCTAssertEqual(try storageSnapshot(), before)
        XCTAssertEqual(try storedPlanner().tasks.map(\.title), [exact])
    }

    // MARK: Huge inputs

    func testOversizedSingleTitleIsRejectedWithoutMutation() throws {
        _ = call("add_tasks", ["titles": ["size sentinel"]])
        let before = try Data(contentsOf: url)
        let title = String(repeating: "x", count: 100_000)
        let (text, isError) = call("add_tasks", ["titles": JSON.array([JSON.string(title)])])
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("2000"), text)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try storedPlanner().tasks.map(\.title), ["size sentinel"])
    }

    func testOversizedTitlesArrayIsRejectedWithoutMutation() throws {
        _ = call("add_tasks", ["titles": ["size sentinel"]])
        let before = try Data(contentsOf: url)
        let count = 500
        let titles = JSON.array((0..<count).map { JSON.string("bulk \($0)") })
        let (text, isError) = call("add_tasks", ["titles": titles])
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("100"), text)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try storedPlanner().tasks.map(\.title), ["size sentinel"])
    }

    func testNotepadSizeBoundary() throws {
        let exact = String(repeating: "y", count: 20_000)
        let (text, isError) = call("write_notepad", ["text": .string(exact)])
        XCTAssertFalse(isError, text)
        XCTAssertEqual(try storedPlanner().notes.first?.text.count, 20_000)

        let over = String(repeating: "z", count: 20_001)
        let (overText, overError) = call("write_notepad", ["text": .string(over)])
        XCTAssertTrue(overError)
        XCTAssertTrue(overText.contains("20000"), overText)
        XCTAssertEqual(try storedPlanner().notes.first?.text.count, 20_000, "the rejected write must not land")
    }

    func testTaskNotesSizeBoundary() throws {
        _ = call("add_tasks", ["titles": ["probe"]])
        let notes = String(repeating: "n", count: 20_000)
        let (ok, okError) = call("update_task", ["task": "probe", "notes": .string(notes)])
        XCTAssertFalse(okError, ok)
        XCTAssertEqual(notesOfTheOnlyTask(), notes)

        let (text, isError) = call(
            "update_task", ["task": "probe", "notes": .string(String(repeating: "n", count: 20_001))])
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("20000"), text)
        XCTAssertEqual(notesOfTheOnlyTask(), notes, "the rejected write must not land")
    }

    private func notesOfTheOnlyTask() -> String? {
        try? storedPlanner().tasks.first?.notes
    }

    // MARK: Every tool's error path

    func testEveryToolErrorPath() {
        _ = call("add_tasks", ["titles": ["probe task"]])
        let cases: [(String, JSON, String)] = [
            ("add_tasks", ["titles": .array([])], "at least one task title"),
            ("list_tasks", ["date": "02/03/2026"], "Enter a yyyy-MM-dd date"),
            (
                "update_overdue",
                ["action": "complete", "tasks": [.string("00000000-0000-4000-8000-000000000001")]],
                "unique task id from list_overdue"
            ),
            ("get_task", .object([:]), "Identify the task by id"),
            ("complete_task", ["task": "ghost"], "No task found"),
            ("reopen_task", ["task": "probe task"], "still open"),
            ("rename_task", ["task": "probe task", "title": "   "], "replacement title text"),
            ("rename_task", ["task": "probe task"], "replacement title text"),
            ("delete_task", ["task": "ghost"], "No task found"),
            ("move_task", ["task": "probe task"], "Set a destination date"),
            ("update_task", ["task": "probe task"], "Supply a field to update"),
            ("update_task", ["task": "probe task", "priority": "urgent"], "Choose priority from"),
            ("update_task", ["task": "probe task", "remind_at": "9:00 am"], "is in the past"),
            ("update_task", ["task": "probe task", "minutes": 900], "1 to 720"),
            ("update_task", ["task": "probe task", "repeat": "sometimes"], "not recognized"),
            ("update_task", ["task": "probe task", "deadline": "next week"], "yyyy-MM-dd"),
            ("snooze_reminder", ["task": "probe task", "minutes": 0], "1 to 1440"),
            ("start_timer", ["minutes": 0], "1 to 720"),
            ("pause_timer", .object([:]), "Start a focus session first"),
            ("resume_timer", .object([:]), "Start a focus session first"),
            ("stop_timer", .object([:]), "Start a focus session first"),
            ("read_notepad", ["date": "inbox"], "Enter a yyyy-MM-dd date"),
            ("write_notepad", .object([:]), "Enter note text"),
            ("write_notepad", ["text": "hi", "mode": "prepend"], "append or replace"),
        ]
        for (tool, args, expected) in cases {
            let (text, isError) = call(tool, args)
            XCTAssertTrue(isError, "\(tool) should fail: \(text)")
            XCTAssertTrue(text.contains(expected), "\(tool): expected \"\(expected)\" in \"\(text)\"")
        }
        XCTAssertEqual(try? storedPlanner().tasks.count, 1, "failed calls must not mutate the planner")
    }

    func testDoneTaskErrorPaths() throws {
        _ = call("add_tasks", ["titles": ["finished"]])
        _ = call("complete_task", ["task": "finished"])
        for (tool, args) in [
            ("complete_task", ["task": "finished"]),
            ("update_task", ["task": "finished", "remind_at": "17:00"]),
            ("update_task", ["task": "finished", "minutes": 10]),
            ("start_timer", ["task": "finished"]),
        ] as [(String, JSON)] {
            let (text, isError) = call(tool, args)
            XCTAssertTrue(isError, "\(tool): \(text)")
        }
    }

    func testStartTimerOnAFutureTaskFails() {
        _ = call("add_tasks", ["titles": ["future thing tomorrow"]])
        let (text, isError) = call("start_timer", ["task": "future thing"])
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("No task found"), text)
    }

    func testTimerStateMachineErrors() {
        _ = call("start_timer", ["minutes": 5])
        let (paused, _) = call("pause_timer")
        XCTAssertTrue(paused.contains("paused"))
        let (resumed, _) = call("resume_timer")
        XCTAssertTrue(resumed.contains("resumed"))
        let (stopped, stopError) = call("stop_timer")
        XCTAssertFalse(stopError, stopped)
        let (again, againError) = call("stop_timer")
        XCTAssertTrue(againError)
        XCTAssertEqual(again, "Start a focus session first.")
    }

    func testCorruptPlannerSurfacesAToolErrorAndBacksUpTheFile() throws {
        try Data("{not json".utf8).write(to: url)
        for tool in ["get_insights", "list_projects", "list_inbox", "list_overdue", "list_tasks", "add_tasks"] {
            let args: JSON = tool == "add_tasks" ? ["titles": ["x"]] : .object([:])
            let (text, isError) = call(tool, args)
            XCTAssertTrue(isError, "\(tool): \(text)")
            XCTAssertTrue(text.contains("Unable to load planner data"), "\(tool): \(text)")
        }
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(siblings.contains { $0.contains("corrupt") }, siblings.joined(separator: ", "))
    }

    func testWrongArgumentTypesAreRejectedWithoutMutation() throws {
        var (text, isError) = call("add_tasks", ["titles": 5])
        XCTAssertTrue(isError, text)
        XCTAssertTrue(text.contains("at least one task title"), text)
        (text, isError) = call("add_tasks", ["titles": .array([JSON.number(1), JSON.number(2)])])
        XCTAssertTrue(isError, text)
        (text, isError) = call("add_tasks", ["titles": .array([JSON.string("   ")])])
        XCTAssertTrue(isError, text)
        (text, isError) = call("list_tasks", ["date": 5])
        XCTAssertTrue(isError, text)
        XCTAssertTrue(text.contains("Invalid argument 'date'"), text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLiteralTitlesKeepMetadata() throws {
        let (text, isError) = call("add_tasks", ["titles": ["buy 5pm tickets !high"], "literal": true])
        XCTAssertFalse(isError, text)
        let task = try XCTUnwrap(storedPlanner().tasks.first)
        XCTAssertEqual(task.title, "buy 5pm tickets !high")
        XCTAssertNil(task.remindAt)
        XCTAssertEqual(task.priority, .none)
    }
}
