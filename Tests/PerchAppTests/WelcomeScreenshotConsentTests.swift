import AppKit
import PlannerCore
import SwiftUI
import XCTest
@testable import PerchApp

/// Persist fixture preferences beside the synthetic planner, never in the user's defaults.
private final class ConsentFilePreferences: PlannerPreferencesAdapter, Sendable {
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
    @MainActor func testCompletingWelcomeLeavesScreenshotImportOffWithoutOptIn() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        XCTAssertFalse(store.prefs.catchScreenshots)
        let delegate = AppDelegate()
        delegate.store = store

        delegate.completeWelcome()

        XCTAssertTrue(store.prefs.welcomeCompleted)
        XCTAssertFalse(store.prefs.catchScreenshots, "Opening the workspace must not opt in to screenshot import")
        let reloaded = makeStore(root)
        XCTAssertTrue(reloaded.prefs.welcomeCompleted)
        XCTAssertFalse(reloaded.prefs.catchScreenshots)
    }

    @MainActor func testCompletingWelcomePreservesStoredOptIn() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        store.updatePrefs { $0.catchScreenshots = true }
        let reloaded = makeStore(root)
        XCTAssertTrue(WelcomeScreenshotConsent(store: reloaded).isEnabled.wrappedValue)
        let delegate = AppDelegate()
        delegate.store = reloaded

        delegate.completeWelcome()

        XCTAssertTrue(reloaded.prefs.welcomeCompleted)
        XCTAssertTrue(reloaded.prefs.catchScreenshots)
        XCTAssertTrue(makeStore(root).prefs.catchScreenshots)
    }

    @MainActor func testExplicitBindingOptInAndOptOutRoundTrip() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        let binding = WelcomeScreenshotConsent(store: store).isEnabled
        XCTAssertFalse(binding.wrappedValue)

        binding.wrappedValue = true

        XCTAssertTrue(store.prefs.catchScreenshots)
        XCTAssertFalse(store.prefs.welcomeCompleted)
        let reloaded = makeStore(root)
        let reloadedBinding = WelcomeScreenshotConsent(store: reloaded).isEnabled
        XCTAssertTrue(reloadedBinding.wrappedValue)
        reloadedBinding.wrappedValue = false
        XCTAssertFalse(reloaded.prefs.catchScreenshots)
        XCTAssertFalse(makeStore(root).prefs.catchScreenshots)
        let delegate = AppDelegate()
        delegate.store = reloaded
        delegate.completeWelcome()
        XCTAssertFalse(makeStore(root).prefs.catchScreenshots)
    }

    @MainActor func testConsentViewPresentsLabelExplanationAndSettingsLocation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = NSApplication.shared
        let store = makeStore(root)
        let host = NSHostingView(
            rootView: WelcomeScreenshotConsent(store: store)
                .environment(\.accessibilityEnabled, true))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        let expected = [
            "Add new screenshots to Clips",
            "While enabled, Perch watches for newly saved screenshots and screen recordings and adds them to Clips. It does not take screenshots.",
            "Change this anytime in Settings > Workspace > Clips.",
        ]
        var text = Set<String>()
        for _ in 0..<25 {
            host.layoutSubtreeIfNeeded()
            text = Self.accessibleText(host)
            if expected.allSatisfy(text.contains) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        for value in expected {
            XCTAssertTrue(text.contains(value), "Consent view did not present: \(value). Found: \(text)")
        }
        XCTAssertFalse(store.prefs.catchScreenshots, "Rendering the choice must not opt in")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("planner.json").path))
    }

    @MainActor private func makeStore(_ root: URL) -> PlannerStore {
        PlannerStore(
            file: PlannerFile(
                url: root.appendingPathComponent("planner.json"),
                preferences: ConsentFilePreferences(url: root.appendingPathComponent("preferences.json"))),
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
            let subviews = (node as? NSView)?.subviews ?? []
            for child in children + contents + subviews { walk(child) }
        }
        walk(root)
        return text
    }
}
