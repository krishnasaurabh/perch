import AppKit
import Combine
import PerchUI
import SwiftUI
import XCTest
@testable import PerchApp
@testable import PlannerCore

final class SettingsGeneralTests: XCTestCase {
    @MainActor func testHoverControlStoresAndReloadsWithoutChangingOtherPreferences() async throws {
        try check(
            \.notchOpenTrigger, choices: [.nothing, .everything, .hover], update: PreferenceUpdate.notchOpenTrigger)
        XCTAssertEqual(SettingsGeneralPane.hoverChoice(.click), .nothing)
        XCTAssertEqual(SettingsGeneralPane.hoverChoice(.doubleClick), .nothing)
    }

    @MainActor func testResetHourControlStoresAndReloadsEveryHour() async throws {
        try check(\.resetHour, choices: Array(0...23), update: PreferenceUpdate.resetHour)
    }

    @MainActor func testCarryControlStoresAndReloads() async throws {
        try check(\.carryMode, choices: [.ask, .never, .auto], update: PreferenceUpdate.carryMode)
    }

    @MainActor func testDefaultLengthControlStoresAndReloads() async throws {
        try check(\.defaultFocusMinutes, choices: [15, 25, 45, 60], update: PreferenceUpdate.defaultFocusMinutes)
    }

    @MainActor func testSavedCustomLengthRemainsVisible() async throws {
        XCTAssertEqual(SettingsGeneralPane.durationUnit(for: 50), AppL10n.format("%lld min", 50))
        XCTAssertEqual(SettingsGeneralPane.durationUnit(for: 45), AppL10n.text("min"))
    }

    @MainActor func testHeadsUpControlStoresAndReloads() async throws {
        try check(\.blockHeadsUp, choices: [.off, .tenMinutes, .fiveMinutes], update: PreferenceUpdate.blockHeadsUp)
    }

    @MainActor func testBlockEndControlStoresAndReloads() async throws {
        try check(\.blockEndAction, choices: [.doNothing, .takeBreak, .ask], update: PreferenceUpdate.blockEndAction)
    }

    @MainActor func testChimeControlStoresAndReloads() async throws {
        try check(\.focusCompletionSound, choices: [true, false], update: PreferenceUpdate.focusCompletionSound)
    }

    @MainActor func testLoginControlChangesSystemThenStoresAndReloads() async throws {
        let fixture = try GeneralSettingsFixture()
        defer { fixture.cleanUp() }
        let feedback = SettingsFailureFeedback()
        var requests: [Bool] = []
        var enabled = true
        for value in [false, true] {
            SettingsGeneralPane.setLoginItem(value, store: fixture.store, feedback: feedback, current: { enabled }) {
                requests.append($0)
                enabled = $0
            }
            XCTAssertEqual(fixture.store.prefs.launchAtLogin, value)
            XCTAssertEqual(try fixture.reloaded().launchAtLogin, value)
            XCTAssertNil(fixture.store.lastError)
        }
        XCTAssertEqual(requests, [false, true])
    }

    @MainActor func testLoginRejectionKeepsPreferenceAndRetryUsesSameChoice() async throws {
        let fixture = try GeneralSettingsFixture()
        defer { fixture.cleanUp() }
        let feedback = SettingsFailureFeedback()
        let original = fixture.store.prefs
        var fail = true
        var requests: [Bool] = []
        SettingsGeneralPane.setLoginItem(false, store: fixture.store, feedback: feedback, current: { true }) { value in
            requests.append(value)
            if fail { throw NSError(domain: "SettingsGeneralTests", code: 1) }
        }
        XCTAssertEqual(fixture.store.prefs, original)
        XCTAssertEqual(try fixture.reloaded(), original)
        let error = try XCTUnwrap(fixture.store.lastError)
        XCTAssertTrue(feedback.canRetry(error))
        fail = false
        feedback.retry(error)
        XCTAssertEqual(requests, [false, false])
        XCTAssertFalse(try fixture.reloaded().launchAtLogin)
        XCTAssertNil(fixture.store.lastError)
    }

    @MainActor func testLoginStorageFailureRollsBackSystemChoice() async throws {
        let fixture = try GeneralSettingsFixture()
        defer { fixture.cleanUp() }
        let original = fixture.store.prefs
        let invalid = Data("invalid planner".utf8)
        try invalid.write(to: fixture.store.file.url)
        var requests: [Bool] = []
        SettingsGeneralPane.setLoginItem(
            true, store: fixture.store, feedback: SettingsFailureFeedback(), current: { false }
        ) { requests.append($0) }
        XCTAssertEqual(requests, [true, false], "Rollback restores the real system state, not a stale preference")
        XCTAssertEqual(fixture.store.prefs, original)
        XCTAssertNotNil(fixture.store.lastError)
        XCTAssertEqual(try Data(contentsOf: fixture.store.file.url), invalid)
    }

    @MainActor func testShortcutControlStoresReloadsAndUpdatesLegacyRegistration() async throws {
        let fixture = try GeneralSettingsFixture()
        defer { fixture.cleanUp() }
        let sync = ShortcutPreferenceSync.connect(store: fixture.store, defaults: fixture.defaults)
        defer { sync.cancel() }
        let choice = OpenShortcut(keyCode: 49, modifiers: 9)
        XCTAssertTrue(ShortcutPreferenceRow.save(ShortcutPreferenceSync.key(choice), in: fixture.store))
        await settle()
        XCTAssertEqual(try fixture.reloaded().openShortcut, choice)
        XCTAssertEqual(ShortcutStore.load(defaults: fixture.defaults), ShortcutPreferenceSync.key(choice))
        fixture.store.undo()
        await settle()
        XCTAssertEqual(ShortcutStore.load(defaults: fixture.defaults), .default)
        XCTAssertEqual(try fixture.reloaded().openShortcut, OpenShortcut())
    }

    @MainActor func testExistingShortcutMigratesOnlyOnce() async throws {
        let fixture = try GeneralSettingsFixture()
        defer { fixture.cleanUp() }
        let custom = ShortcutKey(keyCode: 49, modifiers: [.control, .command])
        ShortcutStore.save(custom, defaults: fixture.defaults, notify: false)
        var sync = ShortcutPreferenceSync.connect(store: fixture.store, defaults: fixture.defaults)
        XCTAssertEqual(try fixture.reloaded().openShortcut, ShortcutPreferenceSync.preference(custom))
        sync.cancel()
        fixture.store.apply { try $0.updatePreference(.openShortcut(OpenShortcut())) }
        // A deliberately reset typed default wins over the old legacy value on the next launch.
        sync = ShortcutPreferenceSync.connect(store: fixture.store, defaults: fixture.defaults)
        defer { sync.cancel() }
        XCTAssertEqual(ShortcutStore.load(defaults: fixture.defaults), .default)
        XCTAssertEqual(try fixture.reloaded().openShortcut, OpenShortcut())
    }

    @MainActor func testRejectedShortcutRestoresStoredAndDisplayedChoice() async throws {
        let fixture = try GeneralSettingsFixture()
        defer { fixture.cleanUp() }
        let sync = ShortcutPreferenceSync.connect(store: fixture.store, defaults: fixture.defaults)
        defer { sync.cancel() }
        fixture.store.apply { try $0.updatePreference(.openShortcut(OpenShortcut(keyCode: 49, modifiers: 9))) }
        await settle()
        ShortcutStore.save(.default, defaults: fixture.defaults, notify: false)
        NotificationCenter.default.post(
            name: ShortcutStore.didFail, object: nil,
            userInfo: [
                "key": ShortcutKey(keyCode: 49, modifiers: [.control, .command]), "restored": ShortcutKey.default,
            ])
        await settle()
        XCTAssertEqual(fixture.store.prefs.openShortcut, OpenShortcut())
        XCTAssertEqual(try fixture.reloaded().openShortcut, OpenShortcut())
        XCTAssertEqual(ShortcutStore.load(defaults: fixture.defaults), .default)
    }

    @MainActor func testLoginRuntimeAppliesDefaultAndUndoWithoutOpeningSettings() async throws {
        let fixture = try GeneralSettingsFixture()
        defer { fixture.cleanUp() }
        var enabled = false
        var requests: [Bool] = []
        let sync = LoginItemPreferenceSync(store: fixture.store, current: { enabled }) {
            requests.append($0)
            enabled = $0
        }
        defer { withExtendedLifetime(sync) {} }
        XCTAssertTrue(enabled)
        fixture.store.apply { try $0.updatePreference(.launchAtLogin(false)) }
        await settle()
        XCTAssertFalse(enabled)
        fixture.store.undo()
        await settle()
        XCTAssertTrue(enabled)
        XCTAssertEqual(requests, [true, false, true])
    }

    @MainActor func testStaleShortcutRejectionCannotReplaceANewerChoice() async throws {
        let fixture = try GeneralSettingsFixture()
        defer { fixture.cleanUp() }
        let sync = ShortcutPreferenceSync.connect(store: fixture.store, defaults: fixture.defaults)
        defer { sync.cancel() }
        let rejected = ShortcutKey(keyCode: 49, modifiers: [.control, .command])
        XCTAssertTrue(ShortcutPreferenceRow.save(rejected, in: fixture.store))
        await settle()
        NotificationCenter.default.post(
            name: ShortcutStore.didFail, object: nil,
            userInfo: ["key": rejected, "restored": ShortcutKey.default])
        let newer = ShortcutKey(keyCode: 36, modifiers: [.option, .command])
        XCTAssertTrue(ShortcutPreferenceRow.save(newer, in: fixture.store))
        await settle()
        XCTAssertEqual(try fixture.reloaded().openShortcut, ShortcutPreferenceSync.preference(newer))
        XCTAssertEqual(ShortcutStore.load(defaults: fixture.defaults), newer)
    }

    @MainActor func testFailedShortcutRestorationRetriesAfterStorageRecovers() async throws {
        let fixture = try GeneralSettingsFixture()
        defer { fixture.cleanUp() }
        let sync = ShortcutPreferenceSync.connect(store: fixture.store, defaults: fixture.defaults)
        defer { sync.cancel() }
        let rejected = ShortcutKey(keyCode: 49, modifiers: [.control, .command])
        XCTAssertTrue(ShortcutPreferenceRow.save(rejected, in: fixture.store))
        await settle()
        let saved = try Data(contentsOf: fixture.store.file.url)
        try Data("unreadable planner".utf8).write(to: fixture.store.file.url)
        ShortcutStore.save(.default, defaults: fixture.defaults, notify: false)
        NotificationCenter.default.post(
            name: ShortcutStore.didFail, object: nil,
            userInfo: ["key": rejected, "restored": ShortcutKey.default])
        await settle()
        XCTAssertNotNil(fixture.store.lastError)
        XCTAssertEqual(fixture.store.prefs.openShortcut, ShortcutPreferenceSync.preference(rejected))
        try saved.write(to: fixture.store.file.url)
        fixture.store.apply { try $0.updatePreference(.focusCompletionSound(true)) }
        await settle()
        XCTAssertEqual(try fixture.reloaded().openShortcut, OpenShortcut())
        XCTAssertTrue(try fixture.reloaded().focusCompletionSound)
    }

    @MainActor private func check<Value: Equatable>(
        _ key: KeyPath<Preferences, Value>, choices: [Value], update: @escaping (Value) -> PreferenceUpdate
    ) throws {
        let fixture = try GeneralSettingsFixture()
        defer { fixture.cleanUp() }
        let binding = SettingsGeneralPane.preference(key, update: update, store: fixture.store)
        for value in choices {
            let before = fixture.store.prefs
            var expected = before
            update(value).apply(to: &expected)
            binding.wrappedValue = value
            XCTAssertEqual(binding.wrappedValue, value)
            XCTAssertEqual(fixture.store.prefs, expected)
            XCTAssertEqual(try fixture.reloaded(), expected)
            XCTAssertNil(fixture.store.lastError)
        }
    }

    @MainActor private func settle() async {
        try? await Task.sleep(for: .milliseconds(60))
    }
}

@MainActor private final class GeneralSettingsFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "SettingsGeneralTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: PlannerStore

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"),
            preferences: UserDefaultsPlannerPreferences(defaults: defaults))
        try file.save(Planner())
        store = PlannerStore(file: file, watching: false)
    }

    func reloaded() throws -> Preferences {
        let file = PlannerFile(
            url: store.file.url,
            preferences: UserDefaultsPlannerPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))))
        return PlannerStore(file: file, watching: false).prefs
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
