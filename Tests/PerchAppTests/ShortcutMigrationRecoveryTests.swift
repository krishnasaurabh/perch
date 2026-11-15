import AppKit
import Combine
import PerchUI
import XCTest
@testable import PerchApp
@testable import PlannerCore

final class ShortcutMigrationRecoveryTests: XCTestCase {
    @MainActor func testFailedInitialMigrationKeepsObservingLaterShortcutChanges() async throws {
        let fixture = try ShortcutMigrationFixture()
        defer { fixture.cleanUp() }
        let original = try Data(contentsOf: fixture.store.file.url)
        let invalid = Data("unreadable planner".utf8)
        try invalid.write(to: fixture.store.file.url)

        let sync = ShortcutPreferenceSync.connect(store: fixture.store, defaults: fixture.defaults)
        defer { sync.cancel() }
        await settle()
        XCTAssertNotNil(fixture.store.lastError)
        XCTAssertFalse(fixture.defaults.bool(forKey: ShortcutPreferenceSync.migrationKey))
        XCTAssertEqual(ShortcutStore.load(defaults: fixture.defaults), fixture.legacy)
        XCTAssertEqual(try Data(contentsOf: fixture.store.file.url), invalid)

        try original.write(to: fixture.store.file.url)
        let choice = ShortcutKey(keyCode: 36, modifiers: [.option, .command])
        XCTAssertTrue(ShortcutPreferenceRow.save(choice, in: fixture.store))
        await settle()
        XCTAssertEqual(try fixture.reloaded(), ShortcutPreferenceSync.preference(choice))
        XCTAssertEqual(ShortcutStore.load(defaults: fixture.defaults), choice)
        XCTAssertTrue(fixture.defaults.bool(forKey: ShortcutPreferenceSync.migrationKey))
        XCTAssertNil(fixture.store.lastError)

        fixture.store.undo()
        await settle()
        XCTAssertEqual(try fixture.reloaded(), OpenShortcut())
        XCTAssertEqual(ShortcutStore.load(defaults: fixture.defaults), .default)
    }

    @MainActor func testPendingImportRetriesOnUnrelatedPublicationWithoutRelaunch() async throws {
        let fixture = try ShortcutMigrationFixture()
        defer { fixture.cleanUp() }
        let original = try Data(contentsOf: fixture.store.file.url)
        try Data("unreadable planner".utf8).write(to: fixture.store.file.url)
        let sync = ShortcutPreferenceSync.connect(store: fixture.store, defaults: fixture.defaults)
        defer { sync.cancel() }
        await settle()
        XCTAssertFalse(fixture.defaults.bool(forKey: ShortcutPreferenceSync.migrationKey))
        XCTAssertEqual(ShortcutStore.load(defaults: fixture.defaults), fixture.legacy)

        try original.write(to: fixture.store.file.url)
        XCTAssertNotNil(fixture.store.apply { try $0.updatePreference(.focusCompletionSound(true)) })
        await settle()
        XCTAssertEqual(try fixture.reloaded(), ShortcutPreferenceSync.preference(fixture.legacy))
        XCTAssertEqual(ShortcutStore.load(defaults: fixture.defaults), fixture.legacy)
        XCTAssertTrue(fixture.store.prefs.focusCompletionSound)
        XCTAssertTrue(fixture.defaults.bool(forKey: ShortcutPreferenceSync.migrationKey))
        XCTAssertNil(fixture.store.lastError)
    }

    @MainActor private func settle() async {
        try? await Task.sleep(for: .milliseconds(60))
    }
}

@MainActor private final class ShortcutMigrationFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "ShortcutMigrationRecoveryTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: PlannerStore
    let legacy = ShortcutKey(keyCode: 49, modifiers: [.control, .command])

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"),
            preferences: UserDefaultsPlannerPreferences(defaults: defaults))
        try file.save(Planner())
        store = PlannerStore(file: file, watching: false)
        ShortcutStore.save(legacy, defaults: defaults, notify: false)
    }

    func reloaded() throws -> OpenShortcut {
        let file = PlannerFile(
            url: store.file.url,
            preferences: UserDefaultsPlannerPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))))
        return PlannerStore(file: file, watching: false).prefs.openShortcut
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
