#if SEGMENTED_KEYBOARD_PROBE
    import AppKit
    import SwiftUI
    @testable import PerchApp

    @MainActor private final class SegmentedKeyboardDriver: ObservableObject {
        @Published var minutes = 45
        @Published var enabled = true
        @Published var visible = true
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
            }.padding(20)
        }
    }

    /// Run outside XCTest so the fixture owns an application's native key loop.
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
            let deadline = ContinuousClock.now + .seconds(3)
            repeat {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                await settle()
            } while !window.isKeyWindow && ContinuousClock.now < deadline
            try require(window.isKeyWindow, "The keyboard fixture must own the key window")
            log("Full keyboard access: \(NSApp.isFullKeyboardAccessEnabled)")
            try require(NSApp.isFullKeyboardAccessEnabled, "The fixture requires effective full keyboard access")
            try require(window.makeFirstResponder(driver.before), "Focus the native positive control")
            await settle()
            try assertEditor(driver.before)
            try await key(code: 48, characters: "\t")
            try assertSelectedAndFocused(45)
            try await testArrowsAndEnds()
            try await testExternalSelection()
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
            try assertNoSegmentFocus()
            try await key(code: 48, characters: "\t")
            try assertSelectedAndFocused(25)
        }

        private func testExitAndCancellation() async throws {
            // Do not settle between selection and Tab: a queued restoration must not reclaim focus.
            try send(code: 124, characters: "\u{f703}")
            try send(code: 48, characters: "\t")
            await settle()
            try assertEditor(driver.after)
            try assertNoSegmentFocus()
            try require(driver.minutes == 45, "The arrow before Tab still selects 45")
            try await key(code: 48, characters: "\u{19}", modifiers: .shift)
            try assertSelectedAndFocused(45)
            try send(code: 123, characters: "\u{f702}")
            try send(code: 48, characters: "\u{19}", modifiers: .shift)
            await settle()
            try assertEditor(driver.before)
            try assertNoSegmentFocus()
            driver.minutes = 60
            await settle()
            try assertEditor(driver.before)
            try await key(code: 48, characters: "\t")
            try assertSelectedAndFocused(60)
        }

        private func testDisabledAndInactive() async throws {
            try send(code: 123, characters: "\u{f702}")
            driver.enabled = false
            driver.minutes = 25
            await settle()
            try assertNoSegmentFocus()
            try require(window.makeFirstResponder(driver.before), "Move out of the disabled group")
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
            try require(other.isKeyWindow, "A stale restore must not activate its old window")
            try require(field.currentEditor() === other.firstResponder, "Preserve the other window's editor")
            try assertNoSegmentFocus()

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
            try assertNoSegmentFocus()
        }

        private func key(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) async throws {
            try send(code: code, characters: characters, modifiers: modifiers)
            await settle()
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
                NSApp.sendEvent(event)
            }
        }

        private func settle() async {
            try? await Task.sleep(for: .milliseconds(180))
            window.contentView?.layoutSubtreeIfNeeded()
        }

        private func assertEditor(_ field: NSTextField) throws {
            log(
                "Native field=\(field.stringValue); editor=\(String(describing: field.currentEditor())); responder=\(String(describing: window.firstResponder)); focused=\(segmentNodes().filter { boolean($0, "isAccessibilityFocused") == true }.map { label($0) ?? "nil" })"
            )
            try require(
                field.currentEditor() != nil && field.currentEditor() === window.firstResponder,
                "The intended native field must retain actual first responder")
        }

        private func assertSelectedAndFocused(_ minutes: Int) throws {
            let controls = segmentNodes()
            log(
                "Expected \(minutes); binding=\(driver.minutes); focused=\(controls.filter { boolean($0, "isAccessibilityFocused") == true }.map { label($0) ?? "nil" })"
            )
            try require(driver.minutes == minutes, "Key action must update the binding to \(minutes)")
            try require(controls.count == 4, "All four native segment buttons must exist")
            for value in [15, 25, 45, 60] {
                let matches = controls.filter { label($0) == String(value) }
                try require(matches.count == 1, "Exactly one native button for \(value)")
                guard let node = matches.first else { return }
                try require(
                    boolean(node, "isAccessibilityFocused") == (value == minutes),
                    "Actual native focus must match the selected value \(minutes)")
                try require(
                    attribute(node, "accessibilityValue") as? String
                        == (value == minutes ? "Selected" : "Not selected"),
                    "Native selected value must match the binding")
            }
        }

        private func assertNoSegmentFocus() throws {
            try require(
                segmentNodes().allSatisfy { boolean($0, "isAccessibilityFocused") != true },
                "Departed, disabled or inactive segments must not retain native focus")
        }

        private func segmentNodes() -> [NSObject] {
            var seen = Set<ObjectIdentifier>()
            var result: [NSObject] = []
            @MainActor func visit(_ node: NSObject) {
                guard seen.insert(ObjectIdentifier(node)).inserted else { return }
                result.append(node)
                for key in ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"]
                {
                    for child in attribute(node, key) as? [NSObject] ?? [] { visit(child) }
                }
                if let view = node as? NSView { view.subviews.forEach(visit) }
            }
            visit(window)
            if let content = window.contentView { visit(content) }
            for owner in [NSApp as NSObject, window, window.contentView, window.firstResponder].compactMap({ $0 }) {
                if let focused = attribute(owner, "accessibilityFocusedUIElement") as? NSObject { visit(focused) }
            }
            return result.filter {
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
            guard condition else { throw SegmentedKeyboardFailure(message: message) }
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
                        try await SegmentedKeyboardCheck().run()
                        exit(0)
                    } catch {
                        FileHandle.standardError.write(Data("FAIL: Segmented native keyboard: \(error)\n".utf8))
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

    final class SegmentedKeyboardTests: XCTestCase {
        func testNativeRovingFocusAndExitCancellation() throws {
            let source = URL(fileURLWithPath: #filePath)
            let root = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            for item in ["Package.swift", "Sources", "Tests"] {
                try FileManager.default.copyItem(
                    at: root.appendingPathComponent(item), to: temporary.appendingPathComponent(item))
            }
            let program = try String(contentsOf: source, encoding: .utf8) + "\nSegmentedKeyboardProbe.run()\n"
            try program.write(
                to: temporary.appendingPathComponent("Sources/Perch/main.swift"), atomically: true, encoding: .utf8)
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
                previous = subprocess.run([
                    'defaults', 'read', '-g', 'AppleKeyboardUIMode',
                ], capture_output=True, text=True, timeout=10)
                try:
                    subprocess.run([
                        'defaults', 'write', '-g', 'AppleKeyboardUIMode', '-int', '3',
                    ], check=True, timeout=10)
                    subprocess.run([
                        str(pathlib.Path(bin_path) / 'Perch'), '-AppleKeyboardUIMode', '3',
                    ], check=True, timeout=60)
                finally:
                    if previous.returncode == 0:
                        subprocess.run([
                            'defaults', 'write', '-g', 'AppleKeyboardUIMode', '-int', previous.stdout.strip(),
                        ], check=True, timeout=10)
                    else:
                        subprocess.run([
                            'defaults', 'delete', '-g', 'AppleKeyboardUIMode',
                        ], check=True, timeout=10)
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
            XCTAssertEqual(process.terminationStatus, 0, result)
            XCTAssertTrue(result.contains("PASS: Segmented native arrows, ends, Tab, back-tab and cancellation"))
        }
    }
#endif
