#if SEGMENTED_KEYBOARD_PROBE
    import AppKit
    import ApplicationServices
    import SwiftUI
    @testable import PerchApp

    @MainActor private final class SegmentedKeyboardDriver: ObservableObject {
        @Published var minutes = 45
        @Published var enabled = true
        @Published var visible = true
        var cancellationSelection: Int?
        let before = NSTextField(string: "Before choices")
        let after = NSTextField(string: "After choices")
    }

    private struct SegmentedKeyboardField: NSViewRepresentable {
        let field: NSTextField
        func makeNSView(context: Context) -> NSTextField { field }
        func updateNSView(_ view: NSTextField, context: Context) {}
    }

    private struct SegmentedKeyboardFixture: View {
        @ObservedObject var driver: SegmentedKeyboardDriver
        var body: some View {
            VStack {
                SegmentedKeyboardField(field: driver.before)
                if driver.visible {
                    PerchSegmented(
                        title: "Minutes to set aside",
                        items: [(15, "15"), (25, "25"), (45, "45"), (60, "60")],
                        selection: $driver.minutes
                    ).disabled(!driver.enabled)
                }
                SegmentedKeyboardField(field: driver.after)
            }
            .padding(20)
            .onExitCommand {
                if let original = driver.cancellationSelection { driver.minutes = original }
            }
        }
    }

    /// Drive the production control from an unbundled application with a real native key loop.
    @MainActor private final class SegmentedKeyboardCheck {
        let driver = SegmentedKeyboardDriver()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false)

        func run() async throws {
            window.isReleasedWhenClosed = false
            let host = NSHostingView(
                rootView: SegmentedKeyboardFixture(driver: driver).environment(\.accessibilityEnabled, true))
            host.sizingOptions = []
            window.contentView = host
            defer { window.close() }
            await activateKeyWindow()
            traceFocus("Key window activated")
            try require(window.isKeyWindow, "The keyboard fixture must own the key window")
            log("Full keyboard access: \(NSApp.isFullKeyboardAccessEnabled)")
            try require(NSApp.isFullKeyboardAccessEnabled, "The fixture requires effective full keyboard access")
            try require(window.makeFirstResponder(driver.before), "Focus the native positive control")
            await settle()
            try assertEditor(driver.before)
            try await key(code: 48, characters: "\t")
            // These are the fixture's only key views; native fields can be focused explicitly.
            // Verify entry once: later key handling can transfer the responder to the hosting view.
            traceFocus("First Tab keyboard ownership")
            let responder = window.firstResponder as? NSView
            try require(
                window.isKeyWindow && responder?.window === window
                    && responder.map { String(reflecting: type(of: $0)) == "SwiftUI.KeyViewProxy" } == true,
                "The segmented group must own the native keyboard focus")
            try assertSelectedAndFocused(45)
            try await testArrowsAndEnds()
            try await testExternalSelection()
            try await testEscapeRestoresSelection()
            try await testExitAndCancellation()
            try await testDisabledAndInactive()
            log("PASS: Segmented native arrows, ends, Tab, back-tab and cancellation")
        }

        private func testArrowsAndEnds() async throws {
            for (code, characters, expected) in [
                (UInt16(124), "\u{f703}", 60), (123, "\u{f702}", 45), (123, "\u{f702}", 25),
                (115, "\u{f729}", 15), (115, "\u{f729}", 15), (119, "\u{f72b}", 60),
                (119, "\u{f72b}", 60), (124, "\u{f703}", 60), (115, "\u{f729}", 15),
            ] {
                try await key(code: code, characters: characters)
                try assertSelectedAndFocused(expected)
            }
        }

        private func testExternalSelection() async throws {
            for value in [25, 45, 60] {
                driver.minutes = value
                await settle()
                try assertSelectedAndFocused(value)
            }
            try require(window.makeFirstResponder(driver.before), "Leave the group via a native destination")
            await settle()
            driver.minutes = 25
            await settle()
            try assertEditor(driver.before)
            try assertFocusLeftSegmentGroup("Departed segments must release native focus")
            try await key(code: 48, characters: "\t")
            try assertSelectedAndFocused(25)
        }

        private func testEscapeRestoresSelection() async throws {
            let original = driver.minutes
            driver.cancellationSelection = original
            defer { driver.cancellationSelection = nil }
            try await key(code: 124, characters: "\u{f703}")
            try assertSelectedAndFocused(45)
            try await key(code: 53, characters: "\u{1b}")
            try assertSelectedAndFocused(original)
        }

        private func testExitAndCancellation() async throws {
            // Do not settle between selection and Tab: a queued restoration must not reclaim focus.
            try send(code: 124, characters: "\u{f703}")
            try send(code: 48, characters: "\t")
            await settle()
            try assertFocusLeftSegmentGroup("Tab must leave the segmented group")
            try assertFocusLeftSegmentGroup("Departed segments must release native focus")
            try require(driver.minutes == 45, "The arrow before Tab still selects 45")
            try await key(code: 48, characters: "\u{19}", modifiers: .shift)
            try assertSelectedAndFocused(45)
            try send(code: 48, characters: "\u{19}", modifiers: .shift)
            await settle()
            try assertKeyPassedThrough("Back-tab must not be swallowed by the group", selection: 45)
            driver.minutes = 60
            await settle()
            try require(
                window.makeFirstResponder(driver.before), "Return to the native destination before the final Tab")
            try assertEditor(driver.before)
            try await key(code: 48, characters: "\t")
            try assertSelectedAndFocused(60)
        }

        private func testDisabledAndInactive() async throws {
            try send(code: 123, characters: "\u{f702}")
            driver.enabled = false
            driver.minutes = 25
            await settle()
            try require(window.makeFirstResponder(driver.before), "Move out of the disabled group")
            try assertFocusLeftSegmentGroup("Disabled segments must release native focus")
            driver.enabled = true
            await settle()
            try assertEditor(driver.before)
            try await key(code: 48, characters: "\t")
            try assertSelectedAndFocused(25)

            let other = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            let field = NSTextField(string: "Other window")
            other.contentView = field
            defer { other.close() }
            try send(code: 124, characters: "\u{f703}")
            other.makeKeyAndOrderFront(nil)
            try require(other.makeFirstResponder(field), "Focus the other window")
            driver.minutes = 60
            await settle()
            traceFocus("Other window active")
            log(
                "Other window responder=\(String(describing: other.firstResponder)); textEditorResigned=\(!(other.firstResponder is NSTextView)); editor=\(String(describing: field.currentEditor()))"
            )
            try require(other.isKeyWindow, "A stale restore must not activate its old window")
            try require(field.currentEditor() === other.firstResponder, "Preserve the other window's editor")
            try assertFocusLeftSegmentGroup("Inactive segments must release native focus")

            window.makeKeyAndOrderFront(nil)
            try require(window.makeFirstResponder(driver.before), "Return to the native destination")
            await settle()
            try await key(code: 48, characters: "\t")
            try assertSelectedAndFocused(60)
            try send(code: 123, characters: "\u{f702}")
            driver.visible = false
            await settle()
            try require(window.makeFirstResponder(driver.before), "Leave the removed group")
            driver.visible = true
            await settle()
            try assertEditor(driver.before)
            try assertFocusLeftSegmentGroup("Reinserted segments must not reclaim native focus")
        }

        private func key(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) async throws {
            try send(code: code, characters: characters, modifiers: modifiers)
            await settle()
            try Task.checkCancellation()
        }

        private func send(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) throws {
            try require(window.isKeyWindow, "Keys must reach the active fixture")
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard
                    let event = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: modifiers,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: characters, charactersIgnoringModifiers: characters,
                        isARepeat: false, keyCode: code)
                else { throw SegmentedKeyboardFailure(message: "Could not construct key event") }
                window.sendEvent(event)
            }
        }

        // AX queries into this process must leave the main actor free to serve them.
        nonisolated static func primeAccessibility() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    let app = AXUIElementCreateApplication(getpid())
                    var raw: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
                    FileHandle.standardError.write(Data("Segmented AX root priming: \(status.rawValue)\n".utf8))
                    if let windows = raw as? [AXUIElement] {
                        for window in windows {
                            var children: CFTypeRef?
                            _ = AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children)
                        }
                    }
                    var focused: CFTypeRef?
                    let focusStatus = AXUIElementCopyAttributeValue(
                        app, kAXFocusedUIElementAttribute as CFString, &focused)
                    FileHandle.standardError.write(
                        Data("Segmented AX focus priming: \(focusStatus.rawValue)\n".utf8))
                    continuation.resume()
                }
            }
        }

        private func activateKeyWindow() async {
            for attempt in 0..<25 {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                await settle()
                log(
                    "Segmented activation attempt \(attempt + 1); policy=\(NSApp.activationPolicy().rawValue); appActive=\(NSApp.isActive)"
                )
                if window.isKeyWindow {
                    if attempt > 0 { log("Segmented key window activated after \(attempt + 1) attempts") }
                    return
                }
            }
            traceFocus("Key window activation failed; appActive=\(NSApp.isActive)")
        }

        private func settle() async {
            try? await Task.sleep(for: .milliseconds(180))
            window.contentView?.layoutSubtreeIfNeeded()
        }

        @discardableResult
        private func traceFocus(_ context: String) -> [NSObject] {
            let nodes = accessibilityNodes(window)
            let beforeEditor = driver.before.currentEditor()
            let afterEditor = driver.after.currentEditor()
            let beforeOwnsFocus = beforeEditor != nil && beforeEditor === window.firstResponder
            let afterOwnsFocus = afterEditor != nil && afterEditor === window.firstResponder
            log(
                "\(context); responder=\(String(describing: window.firstResponder)); textEditorResigned=\(!(window.firstResponder is NSTextView)); beforeEditorOwnsFocus=\(beforeOwnsFocus); afterEditorOwnsFocus=\(afterOwnsFocus); focused=\(nodes.filter { boolean($0, "isAccessibilityFocused") == true }.map { label($0) ?? "nil" })"
            )
            // Dump the full inventory, including native fields and non-button focus proxies.
            // Assertions below reuse this snapshot rather than walking a second AX tree.
            log("Segmented AX inventory begin; context=\(context); count=\(nodes.count)")
            for (index, node) in nodes.enumerated() {
                log(
                    "Segmented AX node \(index); type=\(type(of: node)); role=\(attribute(node, "accessibilityRole") as? String ?? "nil"); label=\(label(node) ?? "nil"); identifier=\(attribute(node, "accessibilityIdentifier") as? String ?? "nil"); isAccessibilityFocused=\(String(describing: boolean(node, "isAccessibilityFocused")))"
                )
            }
            log("Segmented AX inventory end; context=\(context)")
            return nodes
        }

        private func assertEditor(_ field: NSTextField) throws {
            traceFocus("Native field=\(field.stringValue); editor=\(String(describing: field.currentEditor()))")
            try require(
                field.currentEditor() != nil && field.currentEditor() === window.firstResponder,
                "The intended native field must retain actual first responder")
        }

        private func assertFocusLeftSegmentGroup(_ context: String) throws {
            traceFocus(context)
            var responder = window.firstResponder as? NSView
            var responderChain: [String] = []
            while let view = responder {
                responderChain.append(String(reflecting: type(of: view)))
                responder = view.superview
            }
            log("\(context); responderChain=\(responderChain)")
            for typeName in responderChain {
                try require(
                    typeName != "SwiftUI.KeyViewProxy" && !typeName.contains("PerchSegmentFocusAnchorView"),
                    context)
            }
        }

        private func assertKeyPassedThrough(_ context: String, selection: Int) throws {
            traceFocus("\(context); binding=\(driver.minutes)")
            var responder = window.firstResponder as? NSView
            var responderChain: [String] = []
            while let view = responder {
                responderChain.append(String(reflecting: type(of: view)))
                responder = view.superview
            }
            log("\(context); responderChain=\(responderChain)")
            try require(driver.minutes == selection, context)
        }

        private func assertSelectedAndFocused(_ minutes: Int) throws {
            let nodes = traceFocus("Expected \(minutes); binding=\(driver.minutes)")
            let controls = segmentNodes(in: nodes)
            try require(driver.minutes == minutes, "Key action must update the binding to \(minutes)")
            try require(controls.count == 4, "All four native segment buttons must exist")
            for value in [15, 25, 45, 60] {
                let matches = controls.filter { label($0) == String(value) }
                try require(matches.count == 1, "Exactly one native button for \(value)")
                guard let node = matches.first else { return }
                // Semantic-focus publication and clearing are verified separately from key delivery.
                try require(
                    attribute(node, "accessibilityValue") as? String
                        == (value == minutes ? "Selected" : "Not selected"),
                    "Native selected value must match the binding")
            }
        }

        private func accessibilityNodes(_ root: NSObject) -> [NSObject] {
            var seen = Set<ObjectIdentifier>()
            var retained: [NSObject] = []
            @MainActor func walk(_ node: NSObject, depth: Int) {
                guard depth < 40, retained.count < 3000, seen.insert(ObjectIdentifier(node)).inserted else { return }
                retained.append(node)
                var children = [
                    "accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder",
                ]
                .flatMap { attribute(node, $0) as? [NSObject] ?? [] }
                if let view = node as? NSView { children += view.subviews }
                if let window = node as? NSWindow, let content = window.contentView { children.append(content) }
                for child in children { walk(child, depth: depth + 1) }
            }
            walk(root, depth: 0)
            // Some SwiftUI semantic focus nodes exist only through this public getter.
            // Attach them after the normal roots so a hosting root cannot lose its children.
            if let window = root as? NSWindow {
                let owners: [NSObject] =
                    [NSApp, window] + [window.contentView, window.firstResponder].compactMap { $0 }
                for owner in owners {
                    if let focused = attribute(owner, "accessibilityFocusedUIElement") as? NSObject {
                        walk(focused, depth: 0)
                    }
                }
            }
            return retained
        }

        private func segmentNodes(in nodes: [NSObject]) -> [NSObject] {
            nodes.filter {
                attribute($0, "accessibilityRole") as? String == "AXButton"
                    && ["15", "25", "45", "60"].contains(label($0) ?? "")
            }
        }

        private func label(_ node: NSObject) -> String? {
            (attribute(node, "accessibilityLabel") ?? attribute(node, "accessibilityTitle")) as? String
        }

        private func attribute(_ node: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
        }

        private func boolean(_ node: NSObject, _ name: String) -> Bool? {
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector), let implementation = node.method(for: selector) else { return nil }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(implementation, to: Getter.self)(node, selector)
        }

        private func require(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw SegmentedKeyboardFailure(
                    message: "\(message); firstResponder=\(String(describing: window.firstResponder))")
            }
        }

        private func log(_ message: String) {
            FileHandle.standardError.write(Data("\(message)\n".utf8))
        }
    }

    private struct SegmentedKeyboardFailure: Error { let message: String }

    private enum SegmentedKeyboardProbe {
        static func run() {
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.regular)
                Task { @MainActor in
                    do {
                        try await runCheck()
                        exit(0)
                    } catch {
                        FileHandle.standardError.write(Data("FAIL: Segmented native keyboard: \(error)\n".utf8))
                        exit(1)
                    }
                }
                app.run()
            }
        }

        @MainActor private static func runCheck() async throws {
            try require(Bundle.main.bundleIdentifier == nil, "The keyboard fixture must run unbundled")
            try require(
                UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") == 3,
                "The fixture must enable Tab navigation in its argument domain")
            // Prime AppKit's lazy AX publication while a simple native window is fronted,
            // before constructing the actor-isolated control or its observable bindings.
            let primer = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            primer.isReleasedWhenClosed = false
            primer.contentView = NSTextField(labelWithString: "Keyboard fixture")
            primer.orderFront(nil)
            await SegmentedKeyboardCheck.primeAccessibility()
            primer.close()
            let check = SegmentedKeyboardCheck()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await check.run() }
                group.addTask {
                    try await Task.sleep(for: .seconds(60))
                    throw SegmentedKeyboardFailure(message: "Native segmented keyboard check exceeded 60 seconds")
                }
                defer { group.cancelAll() }
                do {
                    try await group.next()
                } catch {
                    FileHandle.standardError.write(
                        Data("\(error); firstResponder=\(String(describing: check.window.firstResponder))\n".utf8))
                    throw error
                }
            }
        }

        private static func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SegmentedKeyboardFailure(message: message) }
        }
    }
#elseif os(macOS)
    import CoreFoundation
    import Foundation
    import XCTest

    /// XCTest cannot reliably own a key window on hosted macOS. Build the same package's
    /// unbundled product and retain all native key, focus and accessibility assertions there.
    final class SegmentedKeyboardTests: XCTestCase {
        func testNativeRovingFocusAndExitCancellation() throws {
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
            let program = try String(contentsOf: source, encoding: .utf8) + "\nSegmentedKeyboardProbe.run()\n"
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
                    '-Xswiftc', '-DSEGMENTED_KEYBOARD_PROBE', '-Xswiftc', '-enable-testing',
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
            XCTAssertEqual(process.terminationStatus, 0, "Native segmented keyboard check failed:\n\(result)")
            XCTAssertTrue(result.contains("PASS: Segmented native arrows, ends, Tab, back-tab and cancellation"))
        }
    }
#endif
