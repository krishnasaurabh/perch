import Foundation
import PlannerTestSupport
import XCTest
@testable import PlannerCore

final class DiskMigrationRegressionTests: XCTestCase {
    private func file() -> PlannerFile {
        PlannerFile(
            url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathComponent("planner.json"))
    }

    func testLegacyWriteUpgradesDiskWithoutChangingExportVersion() throws {
        let file = file()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let raw = Data(#"{"version":1,"tasks":[],"preferences":{"catchCopies":true}}"#.utf8)
        try raw.write(to: file.url)
        let loaded = try file.load()
        XCTAssertEqual(try Data(contentsOf: file.url), raw, "Reads must not migrate the file")
        try file.save(loaded)
        let disk = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any])
        XCTAssertEqual(disk["version"] as? Int, 2)
        let diskBytes = try Data(contentsOf: file.url)
        XCTAssertThrowsError(try PlannerFile.decoder.decode(Planner.self, from: diskBytes))
        XCTAssertNoThrow(try PlannerFile.decodeDocument(diskBytes))
        XCTAssertNotNil(disk["taskOrder"])
        XCTAssertNil((disk["preferences"] as? [String: Any])?["catchCopies"])
        let export = file.url.deletingLastPathComponent().appendingPathComponent("export.json")
        try file.export(to: export)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: export)) as? [String: Any])
        XCTAssertEqual(document["version"] as? Int, 1)
    }

    func testLegacyExplicitOrderWinsOverPhysicalArrayOrder() throws {
        let file = file()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let raw = Data(
            #"""
            {"version":1,"taskOrder":["22222222-2222-2222-2222-222222222222","11111111-1111-1111-1111-111111111111"],"tasks":[
            {"id":"11111111-1111-1111-1111-111111111111","title":"First physical","createdAt":"2026-11-09T12:00:00Z"},
            {"id":"22222222-2222-2222-2222-222222222222","title":"First logical","createdAt":"2026-11-09T12:00:00Z"}]}
            """#.utf8)
        try raw.write(to: file.url)
        XCTAssertEqual(try file.load().tasks.map(\.title), ["First logical", "First physical"])
    }

    func testCarryHasFreshInstanceIdentityAndNoAgentAttribution() throws {
        let step = Subtask(title: "Progress", done: true)
        var p = Planner()
        p.tasks = [
            PlanTask(
                title: "Carry", day: "2026-11-08", createdAt: Fixture.now,
                steps: [step], agentID: "synthetic-agent")
        ]
        var engine = PlannerEngine(planner: p, now: { Fixture.now }, calendar: Fixture.calendar)
        let copy = try XCTUnwrap(engine.carryForward([p.tasks[0].id], to: "2026-11-09").first)
        XCTAssertNil(copy.agentID)
        XCTAssertNotEqual(copy.steps.first?.id, step.id)
        XCTAssertEqual(copy.steps.first?.done, true, "Carry preserves step progress, not step identity")
    }
}
