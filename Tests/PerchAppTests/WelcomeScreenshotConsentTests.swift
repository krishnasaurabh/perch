import AppKit
import PerchUI
import PlannerCore
import SwiftUI
import XCTest
@testable import PerchApp

/// Persist fixture preferences beside the synthetic planner, never in the user's defaults.
private final class WelcomeFilePreferences: PlannerPreferencesAdapter, Sendable {
    let url: URL

    init(url: URL) { self.url = url }

    func load() throws -> DevicePreferences? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(DevicePreferences.self, from: Data(contentsOf: url))
    }

    func save(_ preferences: DevicePreferences?) throws {
        if let preferences {
            try JSONEncoder().encode(preferences).write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

final class WelcomeScreenshotConsentTests: XCTestCase {
    func testWelcomeHeadlineUsesSharedDynamicTypeScale() {
        let title = DesignTokens.TypeRole.currentTask.spec
        let normal = title.scaledSize(for: DynamicTypeSize.large.tokenScale)
        let enlarged = title.scaledSize(for: DynamicTypeSize.accessibility3.tokenScale)
        XCTAssertEqual(normal, title.scaledSize(for: .large))
        XCTAssertEqual(enlarged, title.scaledSize(for: .accessibility3))
        XCTAssertGreaterThan(enlarged, normal)
    }

    @MainActor func testStartCompletesWelcomeAndOpensTodayWithoutEnablingCapture() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        let delegate = AppDelegate()
        delegate.store = store
        var openedToday = false
        WelcomeView.complete(store: store, openToday: true) {
            openedToday = true
            delegate.completeWelcome()
        }
        XCTAssertTrue(openedToday)
        XCTAssertTrue(store.prefs.welcomeCompleted)
        XCTAssertTrue(store.planner.tasks.isEmpty, "Welcome must not seed example tasks")
        XCTAssertFalse(store.prefs.catchScreenshots)
        XCTAssertFalse(store.prefs.catchCopies)
        XCTAssertTrue(makeStore(root).prefs.welcomeCompleted)
    }

    @MainActor func testLookAroundCompletesWithoutOpeningTodayOrChangingLegacyChoices() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        store.updatePrefs { $0.catchScreenshots = true }
        var opened = false
        WelcomeView.complete(store: store, openToday: false) { opened = true }
        XCTAssertFalse(opened)
        XCTAssertTrue(store.prefs.welcomeCompleted)
        XCTAssertTrue(store.prefs.catchScreenshots, "Retired values still round-trip unchanged")
        XCTAssertTrue(makeStore(root).prefs.catchScreenshots)
        XCTAssertTrue(makeStore(root).prefs.welcomeCompleted)
    }

    @MainActor func testOpeningSwitchesPersistIndependentlyAndDoNotCompleteWelcome() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        let opening = WelcomeOpeningPreferences(store: store)
        XCTAssertTrue(opening.clickEnabled.wrappedValue)
        XCTAssertTrue(opening.hoverEnabled.wrappedValue)
        opening.clickEnabled.wrappedValue = false
        XCTAssertFalse(store.prefs.notchClickToOpen)
        XCTAssertEqual(store.prefs.notchOpenTrigger, .hover)
        opening.hoverEnabled.wrappedValue = false
        XCTAssertEqual(store.prefs.notchOpenTrigger, .nothing)
        opening.clickEnabled.wrappedValue = true
        XCTAssertEqual(store.prefs.notchOpenTrigger, .nothing)
        let reloaded = makeStore(root)
        XCTAssertTrue(reloaded.prefs.notchClickToOpen)
        XCTAssertEqual(reloaded.prefs.notchOpenTrigger, .nothing)
        WelcomeOpeningPreferences(store: reloaded).hoverEnabled.wrappedValue = true
        XCTAssertEqual(reloaded.prefs.notchOpenTrigger, .hover)
        XCTAssertTrue(reloaded.prefs.notchClickToOpen)
        XCTAssertFalse(reloaded.prefs.welcomeCompleted)
        reloaded.updatePrefs { $0.notchOpenTrigger = .everything }
        XCTAssertTrue(WelcomeOpeningPreferences(store: reloaded).hoverEnabled.wrappedValue)
        XCTAssertEqual(reloaded.prefs.notchOpenTrigger, .everything, "Displaying Welcome must preserve Everything")
    }

    func testWelcomeAccessibilityReaderPreservesAttributedText() {
        XCTAssertEqual(Self.accessibilityString("Write it down"), "Write it down")
        XCTAssertEqual(
            Self.accessibilityString(NSAttributedString(string: "Give it time")), "Give it time")
        XCTAssertEqual(Self.accessibilityString(NSString(string: "Park the rest")), "Park the rest")
        XCTAssertNil(Self.accessibilityString(nil))
        XCTAssertNil(Self.accessibilityString(42))
    }

    @MainActor func testWelcomePresentsHabitsAndReadOnlyPermissionReasons() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let store = makeStore(root)
        let before = store.prefs
        let host = NSHostingView(
            rootView: WelcomeView {}.environmentObject(store)
                .environment(\.accessibilityEnabled, true))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WelcomeView.windowSize),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(WelcomeView.windowSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        // Accessibility copy is checked by the standalone native probe.
        // This host verifies rendering without completing onboarding or writing data.
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.isVisible)
        XCTAssertGreaterThan(host.bounds.width, 0)
        XCTAssertGreaterThan(host.bounds.height, 0)
        XCTAssertEqual(store.prefs, before, "Rendering Welcome must not change any preference")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("planner.json").path))
    }

    @MainActor func testUnreadablePlannerStillOpensTodayWithoutRewritingData() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("planner.json")
        let corrupt = Data(#"{"version":2,"tasks":5}"#.utf8)
        try corrupt.write(to: url)
        let store = makeStore(root)
        XCTAssertNotNil(store.lastError)
        var opened = 0
        WelcomeView.complete(store: store, openToday: true) { opened += 1 }
        XCTAssertEqual(opened, 1, "Recovery must remain reachable when completion cannot be saved")
        XCTAssertNotNil(store.lastError, "Do not hide the storage failure")
        XCTAssertFalse(store.prefs.welcomeCompleted, "A failed save must not pretend to persist completion")
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertFalse(store.prefs.catchScreenshots)
        XCTAssertFalse(store.prefs.catchCopies)
    }

    @MainActor private func makeStore(_ root: URL) -> PlannerStore {
        PlannerStore(
            file: PlannerFile(
                url: root.appendingPathComponent("planner.json"),
                preferences: WelcomeFilePreferences(url: root.appendingPathComponent("preferences.json"))),
            watching: false)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func accessibilityString(_ value: Any?) -> String? {
        if let attributed = value as? NSAttributedString { return attributed.string }
        return value as? String
    }

}
