#if os(macOS)
    import AppKit
    import ApplicationServices
    import SwiftUI
    import XCTest
    @testable import PerchApp

    final class SegmentedKeyboardTests: XCTestCase {
        @MainActor func testNativeRovingFocusAndExitCancellation() async throws {
            // Keep full keyboard access scoped to this test, without launching a defaults process.
            let key = "AppleKeyboardUIMode" as CFString
            let previous = CFPreferencesCopyValue(
                key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSetValue(
                key, NSNumber(value: 3), kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            XCTAssertTrue(
                CFPreferencesSynchronize(
                    kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
            let app = NSApplication.shared
            let originalPolicy = app.activationPolicy()
            app.setActivationPolicy(.accessory)
            defer {
                app.setActivationPolicy(originalPolicy)
                CFPreferencesSetValue(
                    key, previous, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                XCTAssertTrue(
                    CFPreferencesSynchronize(
                        kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
            }
            let check = SegmentedKeyboardCheck()
            // Preserve the former scenario's 60-second deadline now that it runs in XCTest.
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
                    XCTFail("\(error); firstResponder=\(String(describing: check.window.firstResponder))")
                    throw error
                }
            }
        }
    }

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

    /// Host and prime in the XCTest process that observes the native key loop.
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
            await primeAccessibility()
            traceFocus("Key window activated")
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
            try assertNoSegmentFocus()
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
            traceFocus("Other window active")
            log(
                "Other window responder=\(String(describing: other.firstResponder)); textEditorResigned=\(!(other.firstResponder is NSTextView)); editor=\(String(describing: field.currentEditor()))"
            )
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
        private nonisolated func primeAccessibility() async {
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

        private func settle() async {
            try? await Task.sleep(for: .milliseconds(180))
            window.contentView?.layoutSubtreeIfNeeded()
        }

        private func traceFocus(_ context: String) {
            let beforeEditor = driver.before.currentEditor()
            let afterEditor = driver.after.currentEditor()
            let beforeOwnsFocus = beforeEditor != nil && beforeEditor === window.firstResponder
            let afterOwnsFocus = afterEditor != nil && afterEditor === window.firstResponder
            log(
                "\(context); responder=\(String(describing: window.firstResponder)); textEditorResigned=\(!(window.firstResponder is NSTextView)); beforeEditorOwnsFocus=\(beforeOwnsFocus); afterEditorOwnsFocus=\(afterOwnsFocus); focused=\(segmentNodes().filter { boolean($0, "isAccessibilityFocused") == true }.map { label($0) ?? "nil" })"
            )
        }

        private func assertEditor(_ field: NSTextField) throws {
            traceFocus("Native field=\(field.stringValue); editor=\(String(describing: field.currentEditor()))")
            try require(
                field.currentEditor() != nil && field.currentEditor() === window.firstResponder,
                "The intended native field must retain actual first responder")
        }

        private func assertSelectedAndFocused(_ minutes: Int) throws {
            let controls = segmentNodes()
            traceFocus("Expected \(minutes); binding=\(driver.minutes)")
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
            traceFocus("No segment should retain focus")
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
#endif
