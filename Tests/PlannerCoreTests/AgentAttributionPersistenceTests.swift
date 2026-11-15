import Foundation
import XCTest
@testable import PlannerCore

final class AgentAttributionPersistenceTests: XCTestCase {
    func testHidingExistingTaskAttributionPreservesIdentityAcrossRestartAndUndo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = MemoryPlannerPreferences()
        let file = PlannerFile(url: root.appendingPathComponent("planner.json"), preferences: preferences)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var planner = Planner()
        planner.tasks = [
            PlanTask(title: "Inspect seedlings", day: DayKey(now), createdAt: now, agentID: "sample-agent")
        ]
        try file.save(planner)
        let pipeline = PlannerCommandPipeline(file: file, clock: ClosurePlannerClock { now })
        for enabled in [false, true, false] {
            let updated = try pipeline.updatePreference(.showAgentAttribution(enabled), origin: .user)
            XCTAssertEqual(updated.state.preferences.showAgentAttribution, enabled)
            XCTAssertEqual(updated.state.tasks, planner.tasks)
            let encoded = try JSONEncoder().encode(XCTUnwrap(preferences.load()))
            let restarted = PlannerFile(
                url: file.url,
                preferences: MemoryPlannerPreferences(try JSONDecoder().decode(DevicePreferences.self, from: encoded)))
            XCTAssertEqual(try restarted.load().preferences.showAgentAttribution, enabled)
            XCTAssertEqual(try restarted.load().tasks, planner.tasks)
        }
        let undone = try XCTUnwrap(pipeline.undo())
        XCTAssertTrue(undone.preferences.showAgentAttribution)
        XCTAssertEqual(undone.tasks, planner.tasks)
        let redone = try XCTUnwrap(pipeline.redo())
        XCTAssertFalse(redone.preferences.showAgentAttribution)
        XCTAssertEqual(redone.tasks, planner.tasks)
    }
}
