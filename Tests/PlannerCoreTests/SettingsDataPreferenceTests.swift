import Foundation
import XCTest
@testable import PlannerCore

/// Exercises the data pane's typed setting with a fresh device-preference adapter on reload.
final class SettingsDataPreferenceTests: XCTestCase {
    func testThirtyDaySelectionIsStoredAndReloaded() throws { try roundTrip(.thirtyDays) }
    func testNinetyDaySelectionIsStoredAndReloaded() throws { try roundTrip(.ninetyDays) }
    func testNeverSelectionIsStoredAndReloaded() throws { try roundTrip(.never, initial: .thirtyDays) }

    private func roundTrip(_ value: FinishedTaskRetention, initial: FinishedTaskRetention = .never) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "SettingsDataPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("planner.json")
        let file = PlannerFile(url: url, preferences: UserDefaultsPlannerPreferences(defaults: defaults))
        let pipeline = PlannerCommandPipeline(file: file)
        try pipeline.updatePreference(.finishedTaskRetention(initial), origin: .user)
        let result = try pipeline.updatePreference(.finishedTaskRetention(value), origin: .user)
        XCTAssertEqual(result.state.preferences.finishedTaskRetention, value)
        let freshDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let reloaded = try PlannerFile(
            url: url, preferences: UserDefaultsPlannerPreferences(defaults: freshDefaults)
        ).load()
        XCTAssertEqual(reloaded.preferences.finishedTaskRetention, value)
        try pipeline.undo()
        XCTAssertEqual(try file.load().preferences.finishedTaskRetention, initial)
    }

    func testEmptyParkingLotPersistsAndUndoRestoresItWithoutDeletingTasks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        let pipeline = PlannerCommandPipeline(file: file)
        let task = try pipeline.perform(origin: .user) { commands in
            try commands.parkThought("A parked thought")
            return try commands.addTasks(["Keep this task"], literal: true)[0]
        }.value
        try pipeline.execute(.emptyParkingLot, origin: .user)
        XCTAssertTrue(try file.load().parkedThoughts.isEmpty)
        XCTAssertEqual(try file.load().tasks.map(\.id), [task.id])
        try pipeline.undo()
        XCTAssertEqual(try file.load().parkedThoughts.map(\.text), ["A parked thought"])
        XCTAssertEqual(try file.load().tasks.map(\.id), [task.id])
    }
}
