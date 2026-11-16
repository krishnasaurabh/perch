import Foundation
import PlannerTestSupport
import XCTest
@testable import PlannerCore

/// Each Calendar control goes through the locked command path and a fresh device-preference reader.
final class CalendarSettingsPreferenceTests: XCTestCase {
    func testShowMeetingsIsStoredAndReloaded() throws {
        try roundTrip(.showCalendarMeetings(false), key: \.showCalendarMeetings, expected: false)
    }

    func testCalendarsShownIsStoredAndReloaded() throws {
        try roundTrip(.hiddenCalendarIDs(["calendar-work"]), key: \.hiddenCalendarIDs, expected: ["calendar-work"])
    }

    func testMeetingHeadsUpIsStoredAndReloaded() throws {
        try roundTrip(.meetingHeadsUp(.tenMinutes), key: \.meetingHeadsUp, expected: .tenMinutes)
    }

    func testNotifyWhenClosedIsStoredAndReloaded() throws {
        try roundTrip(.notifyWhenClosed(false), key: \.notifyWhenClosed, expected: false)
    }

    func testPersistentRemindersIsStoredAndReloaded() throws {
        try roundTrip(.persistentReminders(false), key: \.persistentReminders, expected: false)
    }

    func testSnoozeDurationIsStoredAndReloaded() throws {
        try roundTrip(.snoozeMinutes(.fifteenMinutes), key: \.snoozeMinutes, expected: .fifteenMinutes)
    }

    func testMirroringIsStoredAndReloaded() throws {
        try roundTrip(.remindersSync(true), key: \.remindersSync, expected: true)
    }

    func testPhoneEditsIsStoredAndReloaded() throws {
        try roundTrip(.phoneEdits(.bringBack), key: \.phoneEdits, expected: .bringBack)
    }

    private func roundTrip<Value: Equatable>(
        _ action: PreferenceUpdate, key: KeyPath<Preferences, Value>, expected: Value,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "perch-calendar-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("planner.json")
        let adapter = UserDefaultsPlannerPreferences(defaults: defaults)
        let plannerFile = PlannerFile(url: url, preferences: adapter)
        let original = try plannerFile.load().preferences[keyPath: key]
        XCTAssertNotEqual(original, expected, file: file, line: line)
        let pipeline = PlannerCommandPipeline(
            file: plannerFile, clock: ClosurePlannerClock { Fixture.now }, calendar: Fixture.calendar)
        let result = try pipeline.updatePreference(action, origin: .user)
        XCTAssertEqual(result.state.preferences[keyPath: key], expected, file: file, line: line)
        let freshDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let restarted = PlannerFile(url: url, preferences: UserDefaultsPlannerPreferences(defaults: freshDefaults))
        XCTAssertEqual(try restarted.load().preferences[keyPath: key], expected, file: file, line: line)
        XCTAssertEqual(try adapter.load(), DevicePreferences(result.state.preferences), file: file, line: line)
    }
}
