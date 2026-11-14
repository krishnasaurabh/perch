import Foundation
import PlannerTestSupport
import XCTest
@testable import PlannerCore

final class AgentActionRecoveryTests: XCTestCase {
    private func fixture() throws -> (URL, PlannerFile, AgentActionLedger) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        let pipeline = PlannerCommandPipeline(
            file: file, clock: ClosurePlannerClock { Fixture.now }, calendar: Fixture.calendar)
        try pipeline.perform(origin: .background) { commands in
            let before = commands.planner
            let tasks = try commands.addTasks(["First", "Second"], literal: true, agentID: "test-agent")
            try commands.recordAgentChange(from: before, agentID: "test-agent", operation: "add_tasks", at: Fixture.now)
            _ = try commands.requestAgentDeletion(tasks[0].id, agentID: "test-agent", at: Fixture.now)
        }
        return (directory, file, try file.load().agentActions)
    }

    private func recover(_ file: PlannerFile, edit: (inout [String: Any]) throws -> Void) throws -> PlannerRecoveryError
    {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any])
        try edit(&json)
        let damaged = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try damaged.write(to: file.url)
        do {
            _ = try file.load()
            XCTFail("Damaged data must enter read-only recovery.")
            throw PlannerError("Expected recovery.")
        } catch let error as PlannerRecoveryError {
            XCTAssertEqual(try Data(contentsOf: file.url), damaged)
            XCTAssertEqual(try Data(contentsOf: error.originalURL), damaged)
            XCTAssertEqual(
                try PlannerFile.decodeDocument(Data(contentsOf: error.recoveredURL)).agentActions,
                error.recoveredPlanner.agentActions)
            XCTAssertEqual(
                try PlannerFile.decoder.decode([PlannerRecoveryIssue].self, from: Data(contentsOf: error.issuesURL)),
                error.issues)
            return error
        }
    }

    func testUnrelatedTaskDamagePreservesEntireLedgerInBothRecoveryDrafts() throws {
        let (directory, file, ledger) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let error = try recover(file) { json in
            var tasks = try XCTUnwrap(json["tasks"] as? [[String: Any]])
            var damaged = tasks[0]
            damaged["id"] = UUID().uuidString
            damaged["title"] = 42
            tasks.append(damaged)
            json["tasks"] = tasks
        }
        XCTAssertEqual(error.recoveredPlanner.agentActions, ledger)
        XCTAssertEqual(error.quarantinedCount, 1)
        XCTAssertEqual(error.quarantinedFieldCount, 0)
        XCTAssertEqual(error.issues.map(\.path), ["tasks[2].title"])
        // Two tasks, one pending request, one change, and two events survive.
        XCTAssertEqual(error.keptCount, 6)
    }

    func testMalformedLedgerRecordsDoNotDiscardTheirValidNeighbors() throws {
        let (directory, file, ledger) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let error = try recover(file) { json in
            var actions = try XCTUnwrap(json["agentActions"] as? [String: Any])
            for key in ["pending", "changes", "events"] {
                var records = try XCTUnwrap(actions[key] as? [[String: Any]])
                var invalid = records[0]
                invalid["agentID"] = 42
                records.insert(invalid, at: 0)
                actions[key] = records
            }
            json["agentActions"] = actions
        }
        XCTAssertEqual(error.recoveredPlanner.agentActions, ledger)
        XCTAssertEqual(error.quarantinedCount, 3)
        XCTAssertEqual(error.quarantinedFieldCount, 0)
        XCTAssertEqual(
            Set(error.issues.map(\.path)),
            Set([
                "agentActions.pending[0].agentID", "agentActions.changes[0].agentID", "agentActions.events[0].agentID",
            ]))
        XCTAssertEqual(error.keptCount, 6)
    }

    func testMalformedLedgerFieldsAreReportedAndSequenceSurvives() throws {
        for key in ["pending", "changes", "events", "sequence"] {
            let (directory, file, ledger) = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            let error = try recover(file) { json in
                var actions = try XCTUnwrap(json["agentActions"] as? [String: Any])
                actions[key] = "invalid"
                json["agentActions"] = actions
            }
            let recovered = error.recoveredPlanner.agentActions
            XCTAssertEqual(recovered.pending, key == "pending" ? [] : ledger.pending)
            XCTAssertEqual(recovered.changes, key == "changes" ? [] : ledger.changes)
            XCTAssertEqual(recovered.events, key == "events" ? [] : ledger.events)
            XCTAssertEqual(recovered.sequence, ledger.sequence)
            XCTAssertEqual(error.issues.map(\.path), ["agentActions.\(key)"])
            XCTAssertEqual(error.quarantinedCount, 0)
            XCTAssertEqual(error.quarantinedFieldCount, 1)
        }
    }

    func testMalformedLedgerObjectIsReportedWithoutDroppingTasks() throws {
        let (directory, file, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let error = try recover(file) { $0["agentActions"] = "invalid" }
        XCTAssertEqual(error.recoveredPlanner.tasks.count, 2)
        XCTAssertEqual(error.recoveredPlanner.agentActions, AgentActionLedger())
        XCTAssertEqual(error.issues.map(\.path), ["agentActions"])
        XCTAssertEqual(error.quarantinedFieldCount, 1)
    }
}
