import AppKit
import PlannerCore
import SwiftUI
import XCTest
@testable import PerchApp

final class SettingsDisplaySelectionTests: XCTestCase {
    @MainActor
    func testStoredBuiltInIsSelectedAndAutomaticPersistsNil() async throws {
        let screens = [
            SettingsNotchDisplay(id: 1, name: "Internal panel", isBuiltIn: true),
            SettingsNotchDisplay(id: 2, name: "Studio monitor", isBuiltIn: false),
        ]
        try await withPane(stored: "builtIn", displays: screens) { picker, store, adapter in
            XCTAssertEqual(picker.titleOfSelectedItem, AppL10n.text("Built-in display"))
            XCTAssertEqual(picker.itemTitles.filter { $0 == AppL10n.text("Built-in display") }.count, 1)
            XCTAssertEqual(store.prefs.showOnDisplay, "builtIn")
            try self.choose(AppL10n.text("Automatic"), in: picker)
            try self.assertPersisted(nil, store: store, adapter: adapter)
        }
    }

    @MainActor
    func testDisconnectedDisplaySurvivesRenderingAndAutomaticClearsIt() async throws {
        let disconnected = "Unplugged display 27\" — Desk #2"
        let screens = [SettingsNotchDisplay(id: 2, name: "Attached monitor", isBuiltIn: false)]
        try await withPane(stored: disconnected, displays: screens) { picker, store, adapter in
            XCTAssertEqual(picker.titleOfSelectedItem, disconnected)
            XCTAssertEqual(picker.itemTitles.filter { $0 == disconnected }.count, 1)
            XCTAssertFalse(picker.itemTitles.contains(AppL10n.text("Built-in display")))
            try self.assertPersisted(disconnected, store: store, adapter: adapter)
            try self.choose(AppL10n.text("Automatic"), in: picker)
            try self.assertPersisted(nil, store: store, adapter: adapter)
        }
    }

    @MainActor
    func testAttachedExternalDisplayUsesItsExactName() async throws {
        let external = "Studio display — USB-C #1"
        let screens = [
            SettingsNotchDisplay(id: 1, name: "Internal panel", isBuiltIn: true),
            SettingsNotchDisplay(id: 2, name: external, isBuiltIn: false),
        ]
        try await withPane(stored: nil, displays: screens) { picker, store, adapter in
            XCTAssertEqual(picker.titleOfSelectedItem, AppL10n.text("Automatic"))
            XCTAssertFalse(picker.itemTitles.contains("Internal panel"))
            try self.choose(external, in: picker)
            try self.assertPersisted(external, store: store, adapter: adapter)
            try self.choose(AppL10n.text("Automatic"), in: picker)
            try self.assertPersisted(nil, store: store, adapter: adapter)
        }
    }

    @MainActor
    func testDisconnectedBuiltInRetainsRawValueWithoutOfferingBuiltInChoice() async throws {
        try await withPane(stored: "builtIn", displays: []) { picker, store, adapter in
            XCTAssertEqual(picker.titleOfSelectedItem, "builtIn")
            XCTAssertFalse(picker.itemTitles.contains(AppL10n.text("Built-in display")))
            try self.assertPersisted("builtIn", store: store, adapter: adapter)
            try self.choose(AppL10n.text("Automatic"), in: picker)
            try self.assertPersisted(nil, store: store, adapter: adapter)
        }
    }

    @MainActor
    private func withPane(
        stored: String?, displays: [SettingsNotchDisplay],
        check: @MainActor (NSPopUpButton, PlannerStore, MemoryPlannerPreferences) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = MemoryPlannerPreferences()
        let storage = PlannerFile(url: root.appendingPathComponent("planner.json"), preferences: adapter)
        let store = PlannerStore(file: storage, watching: false)
        store.apply { try $0.updatePreference(.showOnDisplay(stored)) }
        XCTAssertNil(store.lastError)
        let before = try JSONEncoder().encode(XCTUnwrap(adapter.load()))

        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        let host = NSHostingView(
            rootView: VStack(alignment: .leading) {
                SettingsNotchPane(displays: { displays })
            }
            .environmentObject(store)
            .environment(\.accessibilityEnabled, true))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.close()
            app.setActivationPolicy(originalPolicy)
        }

        let deadline = ContinuousClock.now + .seconds(3)
        var pickers: [NSPopUpButton] = []
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            pickers = self.pickers(in: host).filter { $0.itemTitles.contains(AppL10n.text("Automatic")) }
            if pickers.count == 1, pickers[0].numberOfItems > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(pickers.count, 1, "The rendered pane must contain exactly one display picker")
        let picker = try XCTUnwrap(pickers.first)
        XCTAssertTrue(picker.isEnabled)
        XCTAssertEqual(
            try JSONEncoder().encode(XCTUnwrap(adapter.load())), before, "Rendering must not rewrite preferences")
        try await check(picker, store, adapter)
        host.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func pickers(in view: NSView) -> [NSPopUpButton] {
        (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap { pickers(in: $0) }
    }

    @MainActor
    private func choose(_ title: String, in picker: NSPopUpButton) throws {
        let item = try XCTUnwrap(picker.item(withTitle: title))
        XCTAssertTrue(item.isEnabled)
        picker.select(item)
        XCTAssertTrue(
            picker.sendAction(picker.action, to: picker.target), "The native picker action must reach its binding")
    }

    @MainActor
    private func assertPersisted(
        _ expected: String?, store: PlannerStore, adapter: MemoryPlannerPreferences,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertNil(store.lastError, file: file, line: line)
        XCTAssertEqual(store.prefs.showOnDisplay, expected, file: file, line: line)
        XCTAssertEqual(try store.file.load().preferences.showOnDisplay, expected, file: file, line: line)
        let encoded = try JSONEncoder().encode(XCTUnwrap(adapter.load()))
        let restored = PlannerStore(
            file: PlannerFile(
                url: store.file.url,
                preferences: MemoryPlannerPreferences(try JSONDecoder().decode(DevicePreferences.self, from: encoded))),
            watching: false)
        XCTAssertEqual(restored.prefs.showOnDisplay, expected, file: file, line: line)
    }
}
