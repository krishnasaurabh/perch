import Foundation
import XCTest
@testable import PlannerCore

final class GeneralSettingsPersistenceTests: XCTestCase {
    func testHoverChoicesPersistAndReload() throws {
        try check(
            \.notchOpenTrigger, choices: [.nothing, .hover, .everything], update: PreferenceUpdate.notchOpenTrigger)
    }

    func testShortcutPersistsAndReloads() throws {
        try check(
            \.openShortcut, choices: [OpenShortcut(keyCode: 49, modifiers: 9), OpenShortcut()],
            update: PreferenceUpdate.openShortcut)
    }

    func testLoginChoicePersistsAndReloads() throws {
        try check(\.launchAtLogin, choices: [false, true], update: PreferenceUpdate.launchAtLogin)
    }

    func testEveryDayBoundaryHourPersistsAndReloads() throws {
        try check(\.resetHour, choices: Array(0...23), update: PreferenceUpdate.resetHour)
    }

    func testYesterdayChoicesPersistAndReload() throws {
        try check(\.carryMode, choices: [.ask, .never, .auto], update: PreferenceUpdate.carryMode)
    }

    func testDefaultBlockLengthsPersistAndReload() throws {
        try check(\.defaultFocusMinutes, choices: [15, 25, 45, 60], update: PreferenceUpdate.defaultFocusMinutes)
    }

    func testHeadsUpChoicesPersistAndReload() throws {
        try check(\.blockHeadsUp, choices: [.off, .tenMinutes, .fiveMinutes], update: PreferenceUpdate.blockHeadsUp)
    }

    func testBlockEndChoicesPersistAndReload() throws {
        try check(\.blockEndAction, choices: [.takeBreak, .doNothing, .ask], update: PreferenceUpdate.blockEndAction)
    }

    func testChimeChoicesPersistAndReload() throws {
        try check(\.focusCompletionSound, choices: [true, false], update: PreferenceUpdate.focusCompletionSound)
    }

    private func check<Value: Equatable>(
        _ key: KeyPath<Preferences, Value>, choices: [Value], update: (Value) -> PreferenceUpdate
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "GeneralSettingsPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"),
            preferences: UserDefaultsPlannerPreferences(defaults: defaults))
        let pipeline = PlannerCommandPipeline(file: file)
        for choice in choices {
            let before = try file.load().preferences
            var expected = before
            update(choice).apply(to: &expected)
            let result = try pipeline.updatePreference(update(choice), origin: .user)
            XCTAssertEqual(result.state.preferences[keyPath: key], choice)
            XCTAssertEqual(result.state.preferences, expected, "Unrelated preferences must not change")
            // Reconstruct both the file and device adapter, not just the in-memory snapshot.
            let restarted = PlannerFile(
                url: file.url,
                preferences: UserDefaultsPlannerPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))))
            XCTAssertEqual(try restarted.load().preferences, expected)
            if before != expected {
                XCTAssertEqual(try pipeline.undo()?.preferences, before)
                XCTAssertEqual(try pipeline.redo()?.preferences, expected)
            }
        }
    }
}
