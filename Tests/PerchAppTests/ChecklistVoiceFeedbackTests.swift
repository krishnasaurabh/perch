#if os(macOS)
    import AppKit
    import ApplicationServices
    import SwiftUI
    import XCTest
    @testable import PerchApp

    final class ChecklistVoiceFeedbackTests: XCTestCase {
        @MainActor
        func testVoicePublisherUpdatesListeningAndFailureWithoutTouchingTypedText() async throws {
            _ = NSApplication.shared
            let policy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
            defer { NSApp.setActivationPolicy(policy) }
            let primer = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            primer.isReleasedWhenClosed = false
            primer.contentView = NSTextField(labelWithString: "Voice fixture")
            primer.makeKeyAndOrderFront(nil)
            await primeAccessibility()
            primer.close()

            // State injection needs neither Services nor microphone/speech permission.
            let voice = VoiceCapture()
            let host = NSHostingView(
                rootView: VoiceFixture(voice: voice)
                    .environment(\.accessibilityEnabled, true))
            host.sizingOptions = []
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setContentSize(NSSize(width: 420, height: 240))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            defer { window.close() }
            await settle(window)
            _ = try await lookup("Dictate instead", in: window)
            XCTAssertFalse(nodes(window).contains { matches($0, "Stop listening") })
            let field = try XCTUnwrap(nodes(window).compactMap { $0 as? NSTextField }.first { $0.isEditable })
            XCTAssertEqual(field.stringValue, "Keep this typed task")

            voice.state = .listening
            await settle(window)
            _ = try await lookup("Stop listening", in: window)
            _ = try await lookup("Listening. Tap the mic to stop.", in: window)
            XCTAssertFalse(nodes(window).contains { matches($0, "Dictate instead") })
            XCTAssertEqual(field.stringValue, "Keep this typed task")

            let error = "Allow Speech Recognition for Perch under System Settings › Privacy & Security."
            voice.state = .error(error)
            await settle(window)
            _ = try await lookup(error, in: window)
            _ = try await lookup("Dictate instead", in: window)
            XCTAssertFalse(nodes(window).contains { matches($0, "Listening. Tap the mic to stop.") })
            XCTAssertEqual(field.stringValue, "Keep this typed task")

            voice.state = .idle
            await settle(window)
            XCTAssertFalse(nodes(window).contains { matches($0, error) })
        }

        private nonisolated func primeAccessibility() async {
            await Task.detached {
                let app = AXUIElementCreateApplication(getpid())
                var raw: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
                for window in (raw as? [AXUIElement]) ?? [] {
                    var children: CFTypeRef?
                    _ = AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children)
                }
            }.value
        }

        @MainActor private func settle(_ window: NSWindow) async {
            try? await Task.sleep(for: .milliseconds(150))
            window.contentView?.layoutSubtreeIfNeeded()
        }

        @MainActor private func value(_ node: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
        }

        @MainActor private func text(_ value: Any?) -> String? {
            if let string = value as? String { return string }
            return (value as? NSAttributedString)?.string
        }

        @MainActor private func nodes(_ root: NSObject) -> [NSObject] {
            var seen = Set<ObjectIdentifier>()
            var result: [NSObject] = []
            @MainActor func walk(_ node: NSObject) {
                guard seen.insert(ObjectIdentifier(node)).inserted else { return }
                result.append(node)
                var children: [NSObject] = []
                for key in ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"]
                {
                    children += (value(node, key) as? [NSObject]) ?? []
                }
                if let view = node as? NSView { children += view.subviews }
                for child in children { walk(child) }
            }
            walk(root)
            if let window = root as? NSWindow, let content = window.contentView { walk(content) }
            return result
        }

        @MainActor private func matches(_ node: NSObject, _ label: String) -> Bool {
            if let button = node as? NSButton,
                button.title == label || text(button.accessibilityLabel()) == label
            {
                return true
            }
            if let field = node as? NSTextField,
                field.stringValue == label || (field.isEditable && field.placeholderString == label)
            {
                return true
            }
            return text(value(node, "accessibilityLabel")) == label
                || text(value(node, "accessibilityValue")) == label
        }

        @MainActor private func lookup(_ label: String, in window: NSWindow) async throws -> NSObject {
            for _ in 0..<10 {
                if let found = nodes(window).first(where: { matches($0, label) }) { return found }
                await settle(window)
            }
            let inventory = nodes(window).map {
                "\(type(of: $0)): role=\(text(value($0, "accessibilityRole")) ?? "") "
                    + "label=\(text(value($0, "accessibilityLabel")) ?? "") "
                    + "value=\(text(value($0, "accessibilityValue")) ?? "") "
                    + "identifier=\(text(value($0, "accessibilityIdentifier")) ?? "")"
            }.joined(separator: "\n")
            FileHandle.standardError.write(Data(inventory.utf8))
            return try XCTUnwrap(nil as NSObject?, "Missing \(label)\n\(inventory)")
        }
    }

    private struct VoiceFixture: View {
        @ObservedObject var voice: VoiceCapture
        @State private var text = "Keep this typed task"
        @FocusState private var focus: Bool
        var body: some View {
            ChecklistCaptureField(
                voice: voice, text: $text, prompt: "Add a task. Tab makes it a step.",
                focus: $focus, onSubmit: {}, onDictate: {})
        }
    }
#endif
