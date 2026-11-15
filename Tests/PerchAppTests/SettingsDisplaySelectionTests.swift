#if SETTINGS_DISPLAY_SELECTION_PROBE
    import AppKit
    import PlannerCore
    import SwiftUI
    @testable import PerchApp

    /// Run the production pane in an application's event loop, not XCTest's host.
    @MainActor
    private enum SettingsDisplaySelectionCheck {
        static let cases = [
            "testStoredBuiltInIsSelectedAndAutomaticPersistsNil",
            "testDisconnectedDisplaySurvivesRenderingAndAutomaticClearsIt",
            "testAttachedExternalDisplayUsesItsExactName",
            "testDisconnectedBuiltInRetainsRawValueWithoutOfferingBuiltInChoice",
        ]

        static func run() async throws {
            try require(Bundle.main.bundleIdentifier == nil, "The display fixture must run unbundled")
            try require(
                UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") == 3,
                "The fixture must enable native keyboard navigation")
            try await testStoredBuiltInIsSelectedAndAutomaticPersistsNil()
            log("PASS: \(cases[0])")
            try await testDisconnectedDisplaySurvivesRenderingAndAutomaticClearsIt()
            log("PASS: \(cases[1])")
            try await testAttachedExternalDisplayUsesItsExactName()
            log("PASS: \(cases[2])")
            try await testDisconnectedBuiltInRetainsRawValueWithoutOfferingBuiltInChoice()
            log("PASS: \(cases[3])")
        }

        static func testStoredBuiltInIsSelectedAndAutomaticPersistsNil() async throws {
            let screens = [
                SettingsNotchDisplay(id: 1, name: "Internal panel", isBuiltIn: true),
                SettingsNotchDisplay(id: 2, name: "Studio monitor", isBuiltIn: false),
            ]
            try await withPane(stored: "builtIn", displays: screens) { picker, store, adapter in
                try equal(picker.titleOfSelectedItem, AppL10n.text("Built-in display"))
                try equal(picker.itemTitles.filter { $0 == AppL10n.text("Built-in display") }.count, 1)
                try equal(store.prefs.showOnDisplay, "builtIn")
                try await choose(AppL10n.text("Automatic"), in: picker)
                try assertPersisted(nil, store: store, adapter: adapter)
            }
        }

        static func testDisconnectedDisplaySurvivesRenderingAndAutomaticClearsIt() async throws {
            let disconnected = "Unplugged display 27\" — Desk #2"
            let screens = [SettingsNotchDisplay(id: 2, name: "Attached monitor", isBuiltIn: false)]
            try await withPane(stored: disconnected, displays: screens) { picker, store, adapter in
                try equal(picker.titleOfSelectedItem, disconnected)
                try equal(picker.itemTitles.filter { $0 == disconnected }.count, 1)
                try require(!picker.itemTitles.contains(AppL10n.text("Built-in display")))
                try assertPersisted(disconnected, store: store, adapter: adapter)
                try await choose(AppL10n.text("Automatic"), in: picker)
                try assertPersisted(nil, store: store, adapter: adapter)
            }
        }

        static func testAttachedExternalDisplayUsesItsExactName() async throws {
            let external = "Studio display — USB-C #1"
            let screens = [
                SettingsNotchDisplay(id: 1, name: "Internal panel", isBuiltIn: true),
                SettingsNotchDisplay(id: 2, name: external, isBuiltIn: false),
            ]
            try await withPane(stored: nil, displays: screens) { picker, store, adapter in
                try equal(picker.titleOfSelectedItem, AppL10n.text("Automatic"))
                try require(!picker.itemTitles.contains("Internal panel"))
                try await choose(external, in: picker)
                try assertPersisted(external, store: store, adapter: adapter)
                try await choose(AppL10n.text("Automatic"), in: picker)
                try assertPersisted(nil, store: store, adapter: adapter)
            }
        }

        static func testDisconnectedBuiltInRetainsRawValueWithoutOfferingBuiltInChoice() async throws {
            try await withPane(stored: "builtIn", displays: []) { picker, store, adapter in
                try equal(picker.titleOfSelectedItem, "builtIn")
                try require(!picker.itemTitles.contains(AppL10n.text("Built-in display")))
                try assertPersisted("builtIn", store: store, adapter: adapter)
                try await choose(AppL10n.text("Automatic"), in: picker)
                try assertPersisted(nil, store: store, adapter: adapter)
            }
        }

        private static func withPane(
            stored: String?, displays: [SettingsNotchDisplay],
            check: @MainActor (NSPopUpButton, PlannerStore, MemoryPlannerPreferences) async throws -> Void
        ) async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let adapter = MemoryPlannerPreferences()
            let storage = PlannerFile(url: root.appendingPathComponent("planner.json"), preferences: adapter)
            let store = PlannerStore(file: storage, watching: false)
            store.apply { try $0.updatePreference(.showOnDisplay(stored)) }
            try require(store.lastError == nil, "Seeding the display preference must succeed")
            // An unset default need not write DevicePreferences at all.
            let before = adapter.load()
            let host = NSHostingView(
                rootView: VStack(alignment: .leading) {
                    SettingsNotchPane(displays: { displays })
                }
                .environmentObject(store)
                .environment(\.accessibilityEnabled, true))
            host.sizingOptions = []
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 900),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.center()
            defer { window.close() }
            let deadline = ContinuousClock.now + .seconds(3)
            var matches: [NSPopUpButton] = []
            while ContinuousClock.now < deadline {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                host.layoutSubtreeIfNeeded()
                matches = pickers(in: host).filter { $0.itemTitles.contains(AppL10n.text("Automatic")) }
                if window.isKeyWindow, matches.count == 1, matches[0].numberOfItems > 0 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            log("Display fixture: key=\(window.isKeyWindow), menus=\(matches.map(\.itemTitles))")
            try require(window.isKeyWindow, "The display fixture must own the key window")
            try equal(matches.count, 1, "The rendered pane must contain exactly one display picker")
            let picker = try unwrap(matches.first, "Missing display picker")
            try require(picker.isEnabled, "The display picker must be enabled")
            try equal(adapter.load(), before, "Rendering must not rewrite preferences")
            try await check(picker, store, adapter)
            host.layoutSubtreeIfNeeded()
        }

        private static func pickers(in view: NSView) -> [NSPopUpButton] {
            (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap { pickers(in: $0) }
        }

        private static func choose(_ title: String, in picker: NSPopUpButton) async throws {
            let menu = try unwrap(picker.menu, "The display picker must have a native menu")
            let matches = menu.items.enumerated().filter { $0.element.title == title }
            try equal(matches.count, 1, "The exact display title must identify one native menu item")
            let match = try unwrap(matches.first, "Missing native display menu item")
            try require(match.element.isEnabled, "The display menu item must be enabled")
            try require(match.element.action != nil, "The native menu item must have an action")
            log("Display menu action: title=\(title), action=\(String(describing: match.element.action))")
            // SwiftUI owns the NSMenuItem action, not the NSPopUpButton's target/action.
            // Invoke that actual menu item; never assign the selection or call the binding directly.
            menu.performActionForItem(at: match.offset)
            try await Task.sleep(for: .milliseconds(100))
            picker.window?.contentView?.layoutSubtreeIfNeeded()
            try equal(picker.titleOfSelectedItem, title, "The native menu action must update the visible selection")
        }

        private static func assertPersisted(
            _ expected: String?, store: PlannerStore, adapter: MemoryPlannerPreferences,
            line: UInt = #line
        ) throws {
            try require(store.lastError == nil, "Display selection must not report an error", line: line)
            try equal(store.prefs.showOnDisplay, expected, "Published preference", line: line)
            try equal(try store.file.load().preferences.showOnDisplay, expected, "Reloaded preference", line: line)
            let encoded = try JSONEncoder().encode(unwrap(adapter.load(), "Selection must persist device preferences"))
            let restored = PlannerStore(
                file: PlannerFile(
                    url: store.file.url,
                    preferences: MemoryPlannerPreferences(
                        try JSONDecoder().decode(DevicePreferences.self, from: encoded))),
                watching: false)
            try equal(restored.prefs.showOnDisplay, expected, "Restarted preference", line: line)
            log("Display preference persisted and restarted: \(String(describing: expected))")
        }

        private static func require(_ value: Bool, _ message: String = "Assertion failed", line: UInt = #line) throws {
            guard value else { throw DisplaySelectionFailure(message: "line \(line): \(message)") }
        }

        private static func equal<T: Equatable>(
            _ actual: T, _ expected: T, _ message: String = "Values differ", line: UInt = #line
        ) throws {
            try require(actual == expected, "\(message): \(actual) != \(expected)", line: line)
        }

        private static func unwrap<T>(_ value: T?, _ message: String, line: UInt = #line) throws -> T {
            guard let value else { throw DisplaySelectionFailure(message: "line \(line): \(message)") }
            return value
        }

        private static func log(_ message: String) {
            FileHandle.standardError.write(Data("\(message)\n".utf8))
        }
    }

    private struct DisplaySelectionFailure: Error { let message: String }

    private enum SettingsDisplaySelectionProbe {
        static func run() {
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.regular)
                Task { @MainActor in
                    do {
                        try await SettingsDisplaySelectionCheck.run()
                        exit(0)
                    } catch {
                        FileHandle.standardError.write(Data("FAIL: Native display selection: \(error)\n".utf8))
                        exit(1)
                    }
                }
                app.run()
            }
        }
    }
#else
    import Foundation
    import XCTest

    final class SettingsDisplaySelectionTests: XCTestCase {
        func testDisplaySelectionThroughNativeMenuItems() throws {
            let source = URL(fileURLWithPath: #filePath)
            let root = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            for item in ["Package.swift", "Sources", "Tests"] {
                try FileManager.default.copyItem(
                    at: root.appendingPathComponent(item), to: temporary.appendingPathComponent(item))
            }
            let main = temporary.appendingPathComponent("Sources/Perch/main.swift")
            let program = try String(contentsOf: source, encoding: .utf8) + "\nSettingsDisplaySelectionProbe.run()\n"
            try program.write(to: main, atomically: true, encoding: .utf8)
            let log = temporary.appendingPathComponent("display-selection.log")
            XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [
                "-c",
                #"""
                import os, pathlib, subprocess, sys
                package = sys.argv[1]
                subprocess.run([
                    'swift', 'build', '--jobs', '2', '--package-path', package,
                    '-Xswiftc', '-DSETTINGS_DISPLAY_SELECTION_PROBE', '-Xswiftc', '-enable-testing',
                    '--product', 'Perch',
                ], check=True, timeout=300)
                bin_path = subprocess.check_output([
                    'swift', 'build', '--show-bin-path', '--package-path', package,
                ], text=True, timeout=30).strip()
                environment = dict(os.environ, PERCH_DATA=str(pathlib.Path(package) / 'data'))
                subprocess.run([
                    str(pathlib.Path(bin_path) / 'Perch'), '-AppleKeyboardUIMode', '3',
                ], env=environment, check=True, timeout=60)
                """#, temporary.path,
            ]
            process.currentDirectoryURL = temporary
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let result = try String(contentsOf: log, encoding: .utf8)
            FileHandle.standardError.write(Data(result.utf8))
            XCTAssertEqual(process.terminationReason, .exit)
            XCTAssertEqual(process.terminationStatus, 0, "Native display selection failed:\n\(result)")
            for name in [
                "testStoredBuiltInIsSelectedAndAutomaticPersistsNil",
                "testDisconnectedDisplaySurvivesRenderingAndAutomaticClearsIt",
                "testAttachedExternalDisplayUsesItsExactName",
                "testDisconnectedBuiltInRetainsRawValueWithoutOfferingBuiltInChoice",
            ] {
                XCTAssertEqual(
                    result.components(separatedBy: .newlines).filter { $0 == "PASS: \(name)" }.count, 1,
                    "Each native case must pass exactly once: \(name)\n\(result)")
            }
        }
    }
#endif
