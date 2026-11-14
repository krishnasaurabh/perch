import AppKit
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

    @MainActor func testWelcomePresentsHabitsAndReadOnlyPermissionReasons() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
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
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let expected = [
            "A calmer way through a busy day",
            "Perch sits in your Mac's notch. Three small habits do most of the work.",
            "Write it down", "Give it time", "Park the rest",
            "Start with three things", "Look around first",
            "Click the notch for everything", "Hover for a quick peek",
            "Nothing to allow yet", "Calendar", "Notifications", "Microphone",
            "Your tasks stay on this Mac.",
        ]
        var text = Set<String>()
        for _ in 0..<25 {
            host.layoutSubtreeIfNeeded()
            text = Self.accessibleText(host)
            if expected.allSatisfy(text.contains) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        for value in expected {
            XCTAssertTrue(text.contains(value), "Welcome did not present: \(value). Found: \(text)")
        }
        XCTAssertFalse(text.contains("Add new screenshots to Clips"))
        XCTAssertFalse(text.contains("Allow"))
        XCTAssertEqual(store.prefs, before, "Rendering Welcome must not change any preference")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("planner.json").path))
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

    @MainActor private static func accessibleText(_ root: NSObject) -> Set<String> {
        var seen = Set<ObjectIdentifier>()
        var text = Set<String>()
        @MainActor func attribute(_ node: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
        }
        @MainActor func walk(_ node: NSObject) {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return }
            for name in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"] {
                if let value = attribute(node, name) as? String { text.insert(value) }
            }
            let children = (attribute(node, "accessibilityChildren") as? [NSObject]) ?? []
            let contents = (attribute(node, "accessibilityContents") as? [NSObject]) ?? []
            let ordered = (attribute(node, "accessibilityChildrenInNavigationOrder") as? [NSObject]) ?? []
            let subviews = (node as? NSView)?.subviews ?? []
            let windowContent = (node as? NSWindow)?.contentView.map { [$0] } ?? []
            for child in children + contents + ordered + subviews + windowContent { walk(child) }
        }
        walk(root)
        return text
    }
}
