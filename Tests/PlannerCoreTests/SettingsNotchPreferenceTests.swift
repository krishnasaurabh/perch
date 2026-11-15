import Foundation
import PlannerTestSupport
import XCTest
@testable import PlannerCore

final class SettingsNotchPreferenceTests: XCTestCase {
    func testProgressLinePersistsAndReloads() throws {
        try roundTrip(\.notchProgressLine, values: [false, true], update: PreferenceUpdate.notchProgressLine)
    }

    func testTimePillPersistsAndReloads() throws {
        try roundTrip(\.notchTimePill, values: [true, false], update: PreferenceUpdate.notchTimePill)
    }

    func testTasksLeftPillPersistsAndReloads() throws {
        try roundTrip(\.notchTaskCount, values: [true, false], update: PreferenceUpdate.notchTaskCount)
    }

    func testPillSidePersistsAndReloads() throws {
        try roundTrip(
            \.notchTimerPlacement, values: [.left, .split, .right], update: PreferenceUpdate.notchTimerPlacement)
    }

    func testNextBlockPersistsAndReloads() throws {
        try roundTrip(\.notchNextBlock, values: [true, false], update: PreferenceUpdate.notchNextBlock)
    }

    func testReminderDotPersistsAndReloads() throws {
        try roundTrip(\.notchReminderDot, values: [false, true], update: PreferenceUpdate.notchReminderDot)
    }

    func testMenuBarDisplayPersistsAndReloads() throws {
        try roundTrip(
            \.menuBarDisplay, values: [.timeLeft, .tasksLeft, .hidden, .icon], update: PreferenceUpdate.menuBarDisplay)
    }

    func testManualPrivacyPersistsAndReloads() throws {
        try roundTrip(\.hideCountsAndTimes, values: [false, true], update: PreferenceUpdate.hideCountsAndTimes)
    }

    private func roundTrip<Value: Equatable>(
        _ keyPath: KeyPath<Preferences, Value>, values: [Value], update: (Value) -> PreferenceUpdate,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = MemoryPlannerPreferences()
        let storage = PlannerFile(url: directory.appendingPathComponent("planner.json"), preferences: adapter)
        let pipeline = PlannerCommandPipeline(
            file: storage, clock: ClosurePlannerClock { Fixture.now }, calendar: Fixture.calendar)

        for value in values {
            let before = try storage.load()
            var expected = before.preferences
            update(value).apply(to: &expected)
            let result = try pipeline.updatePreference(update(value), origin: .user)
            XCTAssertEqual(result.state.preferences, expected, file: file, line: line)
            XCTAssertEqual(try storage.load().preferences, expected, file: file, line: line)
            XCTAssertEqual(try storage.load().tasks, before.tasks, file: file, line: line)

            // Restart from the encoded device preference, not the live in-memory adapter.
            let bytes = try JSONEncoder().encode(XCTUnwrap(adapter.load()))
            let reloadedAdapter = MemoryPlannerPreferences(
                try JSONDecoder().decode(DevicePreferences.self, from: bytes))
            let reopened = PlannerFile(url: storage.url, preferences: reloadedAdapter)
            XCTAssertEqual(try reopened.load().preferences[keyPath: keyPath], value, file: file, line: line)
            XCTAssertEqual(try reopened.load().preferences, expected, file: file, line: line)

            XCTAssertEqual(try pipeline.undo()?.preferences, before.preferences, file: file, line: line)
            XCTAssertEqual(try storage.load().preferences, before.preferences, file: file, line: line)
            XCTAssertEqual(try pipeline.redo()?.preferences, expected, file: file, line: line)
            XCTAssertEqual(try storage.load().preferences, expected, file: file, line: line)
        }
    }
}
