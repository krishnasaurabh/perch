import Foundation
import XCTest
@testable import PlannerCore

/// Each Settings switch goes through the same typed command and device store as the app.
final class AgentSettingsPreferenceTests: XCTestCase {
    func testAddAndEditTasksPersistsAndReloads() throws {
        try roundTrip(\.agentsCanEditTasks, defaultValue: true, update: PreferenceUpdate.agentsCanEditTasks)
    }

    func testStartAndStopTimeBlocksPersistsAndReloads() throws {
        try roundTrip(\.agentsCanControlTime, defaultValue: false, update: PreferenceUpdate.agentsCanControlTime)
    }

    func testReadParkingLotPersistsAndReloads() throws {
        try roundTrip(\.agentsCanReadParkingLot, defaultValue: false, update: PreferenceUpdate.agentsCanReadParkingLot)
    }

    func testShowWhoAddedATaskPersistsAndReloads() throws {
        try roundTrip(\.showAgentAttribution, defaultValue: true, update: PreferenceUpdate.showAgentAttribution)
    }

    func testAskBeforeAgentDeletesPersistsAndReloads() throws {
        try roundTrip(\.confirmAgentDeletes, defaultValue: true, update: PreferenceUpdate.confirmAgentDeletes)
    }

    private func roundTrip(
        _ key: KeyPath<Preferences, Bool>, defaultValue: Bool, update: (Bool) -> PreferenceUpdate
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AgentSettingsPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("planner.json")
        let adapter = UserDefaultsPlannerPreferences(defaults: defaults)
        let file = PlannerFile(url: url, preferences: adapter)
        let pipeline = PlannerCommandPipeline(file: file)
        XCTAssertEqual(try file.load().preferences[keyPath: key], defaultValue)
        for value in [!defaultValue, defaultValue] {
            let before = try file.load()
            let result = try pipeline.updatePreference(update(value), origin: .user)
            XCTAssertEqual(result.state.preferences[keyPath: key], value)
            XCTAssertEqual(try file.load().preferences[keyPath: key], value)
            let restarted = PlannerFile(
                url: url,
                preferences: UserDefaultsPlannerPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))))
            XCTAssertEqual(try restarted.load().preferences[keyPath: key], value)
            XCTAssertEqual(try restarted.load().tasks, before.tasks)
            XCTAssertEqual(try pipeline.undo()?.preferences[keyPath: key], !value)
            XCTAssertEqual(try pipeline.redo()?.preferences[keyPath: key], value)
        }
    }
}
