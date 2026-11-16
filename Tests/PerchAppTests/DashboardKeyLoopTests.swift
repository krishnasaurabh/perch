#if DASHBOARD_KEYBOARD_PROBE
    import AppKit
    import ApplicationServices
    import Foundation
    import SwiftUI
    @testable import PerchApp

    @MainActor
    private final class DashboardKeyLoopCheck {
        @MainActor
        func testHistorySearchHasExplicitTabPredecessor() async throws {
            _ = NSApplication.shared
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
            func tabContent() -> AnyView {
                AnyView(
                    PerchSegmented(
                        title: "Section", items: DashboardView.Tab.allCases.map { ($0, $0.rawValue) },
                        selection: .constant(.history), surface: .sheet
                    ).id(UUID()).environment(\.accessibilityEnabled, true))
            }
            let selection = DashboardSelection(tab: .history)
            let tabHost = DashboardTabsHost(selection: selection, environment: EnvironmentValues())
            tabHost.frame = NSRect(x: 20, y: 450, width: 280, height: 30)
            let search = DashboardSearchField(frame: NSRect(x: 20, y: 380, width: 280, height: 24))
            search.identifier = NSUserInterfaceItemIdentifier(DashboardKeyLoop.searchIdentifier)
            search.isEditable = true
            let agent = NSPopUpButton(frame: NSRect(x: 320, y: 380, width: 150, height: 24))
            agent.addItem(withTitle: "All agents")
            root.addSubview(tabHost)
            root.addSubview(search)
            root.addSubview(agent)
            window.contentView = root
            try await Self.activateKeyWindow(window)
            let backtab = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .shift,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "\u{19}", charactersIgnoringModifiers: "\u{19}", isARepeat: false, keyCode: 48)!
            let tab = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
            for phase in ["initial", "rebuilt"] {
                if phase == "rebuilt" { tabHost.rootView = tabContent() }
                for _ in 0..<30 {
                    root.layoutSubtreeIfNeeded()
                    if DashboardKeyLoop.tabKeyView(in: window) != nil { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                // Recalculation can change SwiftUI's current native key view. Resolve
                // it after installation, never retain the pre-installation candidate.
                for _ in 0..<2 {
                    DashboardKeyLoop.install(in: window)
                    let tabs = try unwrap(DashboardKeyLoop.tabKeyView(in: window))
                    let diagnostic = Self.keyLoopDiagnostic(window, phase: phase)
                    try require(tabs.nextKeyView === search, diagnostic)
                    try require(search.previousKeyView === tabs, diagnostic)
                    try notNil(search.nextKeyView, diagnostic)
                    try reject(search.nextKeyView === search, diagnostic)
                }
                try require(window.makeFirstResponder(search))
                let editor = try unwrap(search.currentEditor())
                try require(window.firstResponder === editor)
                try require(search.handleNavigation(backtab))
                let currentTabs = try unwrap(DashboardKeyLoop.tabKeyView(in: window))
                try require(window.firstResponder === currentTabs, Self.keyLoopDiagnostic(window, phase: phase))
                // A key after leaving the search must not be consumed by its monitor.
                try reject(search.handleNavigation(backtab))
                try require(window.makeFirstResponder(search))
                // Also preserve forward navigation out of the field editor.
                try require(search.handleNavigation(tab))
                try isNil(search.currentEditor())
                try notNil(window.firstResponder)
                try reject(search.handleNavigation(tab))
            }
        }

        @MainActor
        func testEverySectionInstallsInitialTabStopWithoutRequiringSearch() async throws {
            _ = NSApplication.shared
            for section in DashboardView.Tab.allCases {
                let selection = DashboardSelection(tab: section)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                let root = NSView(frame: window.contentLayoutRect)
                let host = DashboardTabsHost(selection: selection, environment: EnvironmentValues())
                host.frame = NSRect(x: 20, y: 450, width: 280, height: 30)
                let action = NSButton(title: "Page action", target: nil, action: nil)
                action.frame = NSRect(x: 20, y: 350, width: 150, height: 30)
                root.addSubview(host)
                root.addSubview(action)
                window.contentView = root
                try await Self.activateKeyWindow(window)
                for _ in 0..<30 {
                    root.layoutSubtreeIfNeeded()
                    if DashboardKeyLoop.tabKeyView(in: window) != nil { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                for _ in 0..<2 {
                    DashboardKeyLoop.install(in: window)
                    let tabs = try unwrap(DashboardKeyLoop.tabKeyView(in: window))
                    try require(window.initialFirstResponder === tabs)
                    try require(root.nextKeyView === tabs)
                    try require(
                        tabs.nextValidKeyView === action, Self.keyLoopDiagnostic(window, phase: section.rawValue))
                }
            }
        }

        @MainActor
        func testArrowAndSpaceUseCurrentSelectionAndDoNotStealPageKeys() async throws {
            _ = NSApplication.shared
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let selection = DashboardSelection()
            let host = DashboardTabsHost(selection: selection, environment: EnvironmentValues())
            host.frame = NSRect(x: 20, y: 450, width: 280, height: 30)
            let root = NSView(frame: window.contentLayoutRect)
            let action = NSButton(title: "Page action", target: nil, action: nil)
            action.frame = NSRect(x: 20, y: 350, width: 150, height: 30)
            root.addSubview(host)
            root.addSubview(action)
            window.contentView = root
            try await Self.activateKeyWindow(window)
            for _ in 0..<30 {
                root.layoutSubtreeIfNeeded()
                if DashboardKeyLoop.tabKeyView(in: window) != nil { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            func event(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            }
            for expected in [DashboardView.Tab.history, .projects] {
                let tabs = try unwrap(DashboardKeyLoop.tabKeyView(in: window))
                try require(window.makeFirstResponder(tabs))
                try require(host.handleSelectionKey(event(124, "\u{f703}")))
                try equal(selection.tab, expected)
                // No run-loop yield between Right and Space: activation reads the model,
                // never the old SwiftUI Button closure from the preceding section.
                try require(host.handleSelectionKey(event(49, " ")))
                try equal(selection.tab, expected)
            }
            try require(window.makeFirstResponder(action))
            try reject(host.handleSelectionKey(event(123, "\u{f702}")))
            try reject(host.handleSelectionKey(event(49, " ")))
            try equal(selection.tab, .projects)
            let tabs = try unwrap(DashboardKeyLoop.tabKeyView(in: window))
            try require(window.makeFirstResponder(tabs))
            try reject(host.handleSelectionKey(event(123, "\u{f702}", flags: .command)))
            try equal(selection.tab, .projects)
            try require(host.moveFocus(backward: false))
            try require(window.firstResponder === action)
            await Task.yield()
            try require(window.firstResponder === action, "Leaving the strip must cancel deferred restoration")
        }

        @MainActor
        func testSelectionChangesPreserveHostedRootAndRefreshHistoryLinks() async throws {
            _ = NSApplication.shared
            let selection = DashboardSelection()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let root = NSView(frame: window.contentLayoutRect)
            let host = DashboardTabsHost(selection: selection, environment: EnvironmentValues())
            host.frame = NSRect(x: 20, y: 450, width: 280, height: 30)
            let search = DashboardSearchField(frame: NSRect(x: 20, y: 380, width: 280, height: 24))
            search.identifier = NSUserInterfaceItemIdentifier(DashboardKeyLoop.searchIdentifier)
            let action = NSButton(title: "Page action", target: nil, action: nil)
            action.frame = NSRect(x: 20, y: 350, width: 150, height: 30)
            root.addSubview(host)
            root.addSubview(action)
            window.contentView = root
            try await Self.activateKeyWindow(window)
            for _ in 0..<30 {
                root.layoutSubtreeIfNeeded()
                if DashboardKeyLoop.tabKeyView(in: window) != nil { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            selection.tab = .history
            root.addSubview(search)
            host.refreshKeyLoop()
            var tabs = try unwrap(DashboardKeyLoop.tabKeyView(in: window))
            try require(tabs.nextKeyView === search)
            try require(search.previousKeyView === tabs)
            search.removeFromSuperview()
            selection.tab = .projects
            host.refreshKeyLoop()
            tabs = try unwrap(DashboardKeyLoop.tabKeyView(in: window))
            try require(window.initialFirstResponder === tabs)
            try require(tabs.nextValidKeyView === action)
            try reject(tabs.nextKeyView === search)
            try require(host.selectionState === selection)
        }

        @MainActor
        func testProjectActionsAreNativeTabStopsAndSpaceActivatesOnce() async throws {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let selection = DashboardSelection(tab: .projects)
            let root = NSView(frame: window.contentLayoutRect)
            let host = DashboardTabsHost(selection: selection, environment: EnvironmentValues())
            host.frame = NSRect(x: 20, y: 450, width: 280, height: 30)
            var actions = 0
            let firstHost = NSHostingView(
                rootView: DashboardProjectDeleteButton { actions += 1 }.environment(\.accessibilityEnabled, true))
            let secondHost = NSHostingView(
                rootView: DashboardProjectDeleteButton { actions += 10 }.environment(\.accessibilityEnabled, true))
            let disabledHost = NSHostingView(
                rootView: DashboardProjectDeleteButton { actions += 100 }.disabled(true)
                    .environment(\.accessibilityEnabled, true))
            firstHost.frame = NSRect(x: 20, y: 350, width: 150, height: 40)
            secondHost.frame = NSRect(x: 20, y: 280, width: 150, height: 40)
            disabledHost.frame = NSRect(x: 20, y: 210, width: 150, height: 40)
            root.addSubview(host)
            root.addSubview(firstHost)
            root.addSubview(secondHost)
            root.addSubview(disabledHost)
            window.contentView = root
            @MainActor func targets(_ view: NSView) -> [DashboardProjectActionView] {
                (view as? DashboardProjectActionView).map { [$0] } ?? view.subviews.flatMap(targets)
            }
            try await Self.activateKeyWindow(window)
            for _ in 0..<30 {
                root.layoutSubtreeIfNeeded()
                if DashboardKeyLoop.tabKeyView(in: window) != nil,
                    targets(firstHost).count == 1, targets(secondHost).count == 1, targets(disabledHost).count == 1
                {
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let first = try unwrap(targets(firstHost).first)
            let second = try unwrap(targets(secondHost).first)
            let disabled = try unwrap(targets(disabledHost).first)
            try equal(first.accessibilityLabel(), AppL10n.text("Delete project"))
            try equal(first.accessibilityIdentifier(), "dashboard-project-delete")
            try reject(disabled.isEnabled)
            try reject(disabled.accessibilityPerformPress())
            @MainActor func send(
                _ code: UInt16, _ text: String, flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false
            ) {
                for phase in [NSEvent.EventType.keyDown, .keyUp] {
                    let event = NSEvent.keyEvent(
                        with: phase, location: .zero, modifierFlags: flags,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: text, charactersIgnoringModifiers: text,
                        isARepeat: repeatKey, keyCode: code)!
                    NSApp.sendEvent(event)
                }
            }
            DashboardKeyLoop.install(in: window)
            let tabs = try unwrap(DashboardKeyLoop.tabKeyView(in: window))
            try require(tabs.nextValidKeyView === first)
            try require(first.nextValidKeyView === second)
            try require(second.nextValidKeyView === tabs)
            try require(window.makeFirstResponder(tabs))
            send(48, "\t")
            try require(window.firstResponder === first)
            send(49, " ")
            try equal(actions, 1)
            send(49, " ", repeatKey: true)
            try equal(actions, 1, "Holding Space must not repeat a destructive action")
            send(49, " ", flags: .command)
            try equal(actions, 1, "Command-Space is not project deletion")
            send(48, "\t")
            try require(window.firstResponder === second)
            send(48, "\t", flags: .shift)
            try require(window.firstResponder === first)
            send(48, "\t", flags: .shift)
            try require(window.firstResponder === tabs)
            first.isEnabled = false
            DashboardKeyLoop.install(in: window)
            try require(tabs.nextValidKeyView === second)
            secondHost.removeFromSuperview()
            DashboardKeyLoop.install(in: window)
            try reject(tabs.nextKeyView === second, "Detached project actions must leave the loop")
            try reject(second.accessibilityPerformPress(), "Detached actions cannot delete projects")
            try equal(actions, 1)
        }

        @MainActor
        private static func activateKeyWindow(
            _ window: NSWindow, file: StaticString = #filePath, line: UInt = #line
        ) async throws {
            for attempt in 0..<25 {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(180))
                print(
                    "Dashboard activation attempt \(attempt + 1): key=\(window.isKeyWindow), "
                        + "appActive=\(NSApp.isActive), policy=\(NSApp.activationPolicy().rawValue)")
                if window.isKeyWindow { break }
            }
            _ = try unwrap(
                window.isKeyWindow ? window : nil,
                "The dashboard fixture must own the key window; "
                    + "appActive=\(NSApp.isActive), policy=\(NSApp.activationPolicy().rawValue)",
                file: file, line: line)
        }

        @MainActor
        private static func keyLoopDiagnostic(_ window: NSWindow, phase: String) -> String {
            func identity(_ object: AnyObject?) -> String {
                guard let object else { return "nil" }
                return "\(type(of: object))@\(ObjectIdentifier(object))"
            }
            func descendants(_ view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap(descendants)
            }
            let views = window.contentView.map(descendants) ?? []
            let links = views.filter { $0.canBecomeKeyView || $0 is DashboardTabsHost }.prefix(100).map { view in
                "\(identity(view)) previous=\(identity(view.previousKeyView)) next=\(identity(view.nextKeyView))"
            }.joined(separator: "\n")
            return "\(phase): first=\(identity(window.firstResponder)) "
                + "tabs=\(identity(DashboardKeyLoop.tabKeyView(in: window)))\n\(links)"
        }

    }

    // Portable assertion primitives.
    private func require(
        _ value: Bool, _ message: String = "Assertion failed", file: StaticString = #filePath, line: UInt = #line
    ) throws {
        guard value else { throw DashboardKeyboardFailure(message: "\(file):\(line): \(message)") }
    }
    private func reject(
        _ value: Bool, _ message: String = "Expected false", file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try require(!value, message, file: file, line: line)
    }
    private func equal<T: Equatable>(
        _ actual: T, _ expected: T, _ message: String = "Values differ", file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try require(actual == expected, "\(message): \(actual) != \(expected)", file: file, line: line)
    }
    private func notNil<T>(
        _ value: T?, _ message: String = "Missing value", file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try require(value != nil, message, file: file, line: line)
    }
    private func isNil<T>(
        _ value: T?, _ message: String = "Expected nil", file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try require(value == nil, message, file: file, line: line)
    }
    private func unwrap<T>(
        _ value: T?, _ message: String = "Missing value", file: StaticString = #filePath, line: UInt = #line
    ) throws -> T {
        guard let value else { throw DashboardKeyboardFailure(message: "\(file):\(line): \(message)") }
        return value
    }
    private struct DashboardKeyboardFailure: Error { let message: String }
    // End portable assertion primitives.

    private enum DashboardKeyboardProbe {
        static func run() {
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.regular)
                Task { @MainActor in
                    do {
                        try await runChecks()
                        exit(0)
                    } catch {
                        FileHandle.standardError.write(Data("FAIL: Dashboard native keyboard: \(error)\n".utf8))
                        exit(1)
                    }
                }
                app.run()
            }
        }

        @MainActor private static func runChecks() async throws {
            try require(Bundle.main.bundleIdentifier == nil, "The keyboard fixture must run unbundled")
            try require(
                UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") == 3,
                "The fixture must enable Tab navigation in its argument domain")
            try require(NSApp.isFullKeyboardAccessEnabled, "The fixture requires effective full keyboard access")
            // Prime AppKit's lazy AX publication before constructing the SwiftUI controls.
            let primer = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            primer.isReleasedWhenClosed = false
            primer.contentView = NSTextField(labelWithString: "Keyboard fixture")
            primer.orderFront(nil)
            await primeAccessibility()
            primer.close()
            let check = DashboardKeyLoopCheck()
            try await check.testHistorySearchHasExplicitTabPredecessor()
            log("PASS: Dashboard testHistorySearchHasExplicitTabPredecessor")
            try await check.testEverySectionInstallsInitialTabStopWithoutRequiringSearch()
            log("PASS: Dashboard testEverySectionInstallsInitialTabStopWithoutRequiringSearch")
            try await check.testArrowAndSpaceUseCurrentSelectionAndDoNotStealPageKeys()
            log("PASS: Dashboard testArrowAndSpaceUseCurrentSelectionAndDoNotStealPageKeys")
            try await check.testSelectionChangesPreserveHostedRootAndRefreshHistoryLinks()
            log("PASS: Dashboard testSelectionChangesPreserveHostedRootAndRefreshHistoryLinks")
            try await check.testProjectActionsAreNativeTabStopsAndSpaceActivatesOnce()
            log("PASS: Dashboard testProjectActionsAreNativeTabStopsAndSpaceActivatesOnce")
        }

        private static func log(_ message: String) {
            FileHandle.standardError.write(Data("\(message)\n".utf8))
        }

        nonisolated private static func primeAccessibility() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    let app = AXUIElementCreateApplication(getpid())
                    var raw: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
                    log("Dashboard AX root priming: \(status.rawValue)")
                    if let windows = raw as? [AXUIElement] {
                        for window in windows {
                            var children: CFTypeRef?
                            _ = AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children)
                        }
                    }
                    var focused: CFTypeRef?
                    let focusStatus = AXUIElementCopyAttributeValue(
                        app, kAXFocusedUIElementAttribute as CFString, &focused)
                    log("Dashboard AX focus priming: \(focusStatus.rawValue)")
                    continuation.resume()
                }
            }
        }
    }
#else
    import AppKit
    import CoreFoundation
    import Foundation
    import XCTest
    @testable import PerchApp

    /// Keep key-window scenarios in one unbundled application, not the XCTest process.
    final class DashboardKeyLoopTests: XCTestCase {
        func testNativeDashboardKeyboardScenarios() throws {
            // The argument domain identifies the child's mode. Effective keyboard access also
            // needs the global preference, which is restored on success, failure and timeout.
            let key = "AppleKeyboardUIMode" as CFString
            let previous = CFPreferencesCopyValue(
                key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSetValue(
                key, NSNumber(value: 3), kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost)
            XCTAssertTrue(
                CFPreferencesSynchronize(
                    kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
            defer {
                CFPreferencesSetValue(
                    key, previous, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                XCTAssertTrue(
                    CFPreferencesSynchronize(
                        kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
            }
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
            let program = try String(contentsOf: source, encoding: .utf8) + "\nDashboardKeyboardProbe.run()\n"
            try program.write(to: main, atomically: true, encoding: .utf8)
            let log = temporary.appendingPathComponent("keyboard.log")
            XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [
                "-c",
                #"""
                import pathlib, subprocess, sys
                package = sys.argv[1]
                subprocess.run([
                    'swift', 'build', '--jobs', '2', '--package-path', package,
                    '-Xswiftc', '-DDASHBOARD_KEYBOARD_PROBE', '-Xswiftc', '-enable-testing',
                    '--product', 'Perch',
                ], check=True, timeout=300)
                bin_path = subprocess.check_output([
                    'swift', 'build', '--show-bin-path', '--package-path', package,
                ], text=True, timeout=30).strip()
                subprocess.run([
                    str(pathlib.Path(bin_path) / 'Perch'), '-AppleKeyboardUIMode', '3',
                ], check=True, timeout=120)
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
            XCTAssertEqual(process.terminationStatus, 0, "Native dashboard keyboard check failed:\n\(result)")
            let lines = result.components(separatedBy: .newlines).filter { !$0.isEmpty }
            for marker in [
                "PASS: Dashboard testHistorySearchHasExplicitTabPredecessor",
                "PASS: Dashboard testEverySectionInstallsInitialTabStopWithoutRequiringSearch",
                "PASS: Dashboard testArrowAndSpaceUseCurrentSelectionAndDoNotStealPageKeys",
                "PASS: Dashboard testSelectionChangesPreserveHostedRootAndRefreshHistoryLinks",
                "PASS: Dashboard testProjectActionsAreNativeTabStopsAndSpaceActivatesOnce",
            ] {
                XCTAssertEqual(lines.filter { $0 == marker }.count, 1, "Missing or repeated native scenario: \(marker)")
            }
        }
        @MainActor
        func testWeekKeyboardTargetRejectsAmbiguousOrDetachedLaunchers() async {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
            window.contentView = root
            let target = WeekMenuKeyboardTarget()
            XCTAssertNil(target.popup())
            let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 28, height: 28))
            root.addSubview(anchor)
            target.anchor = anchor
            XCTAssertNil(target.popup())
            let button = NSPopUpButton(frame: anchor.frame)
            root.addSubview(button)
            XCTAssertTrue(target.popup() === button)
            let other = NSPopUpButton(frame: anchor.frame)
            root.addSubview(other)
            XCTAssertNil(target.popup())
            other.isHidden = true
            XCTAssertTrue(target.popup() === button)
            button.isEnabled = false
            XCTAssertNil(target.popup())
        }

        @MainActor
        func testNativeSearchPublishesTypedQuery() async {
            let field = DashboardSearchField(frame: .zero)
            var observed = ""
            field.onChange = { observed = $0 }
            field.stringValue = "alpha"
            field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            XCTAssertEqual(observed, "alpha")
            XCTAssertTrue(field.delegate === field)
        }

        @MainActor
        func testDetachedSearchDoesNotConsumeNavigationOrTextCommands() async {
            let field = DashboardSearchField(frame: .zero)
            let editor = NSTextView(frame: .zero)
            XCTAssertFalse(
                field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
            XCTAssertFalse(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
            XCTAssertFalse(
                field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        }
    }
#endif
