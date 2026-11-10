import Foundation
import PlannerTestSupport
import XCTest
@testable import PlannerCore
@testable import PerchMCP

final class MigrationConcurrencyTests: XCTestCase {
    func testConcurrentMCPAndApplicationCommandsMigrateOnceWithoutLostWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("planner.json")
        let adapter = MemoryPlannerPreferences()
        let file = PlannerFile(url: url, preferences: adapter)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data(
            #"{"version":1,"tasks":[],"preferences":{"catchCopies":true,"defaultFocusMinutes":40}}"#.utf8)
        try original.write(to: url)
        let lock = NSLock()
        var errors: [String] = []
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            let writer = PlannerFile(url: url, preferences: adapter)
            do {
                if index.isMultiple(of: 2) {
                    let server = MCPServer(
                        tools: AgentTools(file: writer, now: { Fixture.now }, calendar: Fixture.calendar),
                        version: "test")
                    let request: JSON = [
                        "jsonrpc": "2.0", "id": .number(Double(index)), "method": "tools/call",
                        "params": [
                            "name": "add_tasks",
                            "arguments": ["titles": [.string("MCP item \(index)")], "day": "inbox"],
                        ],
                    ]
                    guard let response = server.handle(request), response["result"]?["isError"]?.bool == false else {
                        throw PlannerError("MCP command failed")
                    }
                } else {
                    let pipeline = PlannerCommandPipeline(
                        file: writer, clock: ClosurePlannerClock { Fixture.now }, calendar: Fixture.calendar)
                    try pipeline.execute(
                        .addTasks(["App item \(index)"], day: .inbox, literal: true, agentID: nil), origin: .user)
                }
            } catch {
                lock.lock(); errors.append(String(describing: error)); lock.unlock()
            }
        }
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
        let loaded = try file.load()
        XCTAssertEqual(loaded.tasks.count, 32)
        XCTAssertEqual(Set(loaded.tasks.map(\.id)).count, 32)
        XCTAssertEqual(Set(loaded.tasks.map(\.title)).count, 32)
        XCTAssertTrue(loaded.preferences.catchCopies)
        XCTAssertEqual(loaded.preferences.defaultFocusMinutes, 40)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual((saved["taskOrder"] as? [String])?.count, 32)
        XCTAssertEqual(saved["version"] as? Int, 2)
        let migrations = try FileManager.default.contentsOfDirectory(
            at: file.migrationDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(migrations.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(migrations.first)), original)
    }
}
