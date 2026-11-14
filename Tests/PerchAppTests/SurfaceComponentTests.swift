import AppKit
import PerchUI
import SwiftUI
import XCTest
@testable import PerchApp

final class SurfaceComponentTests: XCTestCase {
    @MainActor func testGridUsesDotDiameterAndSpacingWithoutCoveringGaps() async {
        let path = DotGridSheet<EmptyView>.gridPath(in: CGSize(width: 48, height: 32))
        var dots = 0
        path.forEach { if case .closeSubpath = $0 { dots += 1 } }
        XCTAssertEqual(dots, 6)
        XCTAssertEqual(path.boundingRect.minX, 8 - 1.1 / 2, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.maxX, 40 + 1.1 / 2, accuracy: 0.001)
        XCTAssertTrue(path.contains(CGPoint(x: 8, y: 8)))
        XCTAssertFalse(path.contains(CGPoint(x: 16, y: 16)))
        XCTAssertTrue(DotGridSheet<EmptyView>.gridPath(in: .zero).isEmpty)
        XCTAssertEqual(DotGridSheet<EmptyView>.Kind.panel.bottomRadius, 24)
        XCTAssertEqual(DotGridSheet<EmptyView>.Kind.window.bottomRadius, 0)
    }

    @MainActor func testCardInsetsAndCurrentTaskRadiusUseTheContract() async {
        let card = Card(.paper) { Color.clear.frame(width: 20, height: 20) }
        XCTAssertEqual(card.cornerRadius, 20)
        XCTAssertEqual(Card(.butter, kind: .currentTask) { EmptyView() }.cornerRadius, 14)
        XCTAssertEqual(Self.measure(card.frame(width: 200)).height, 52, accuracy: 1)
    }

    @MainActor func testPillSizesAndLargerTextGrowInsteadOfClipping() async {
        for (size, height) in [(PerchPill.Size.small, 22.0), (.regular, 28.0), (.large, 34.0)] {
            let pill = PerchPill("Now", size: size)
            XCTAssertEqual(Self.measure(pill).height, height, accuracy: 1)
        }
        let normal = Self.measure(PerchPill("Now"))
        let enlarged = Self.measure(PerchPill("Now").environment(\.dynamicTypeSize, .accessibility3))
        XCTAssertGreaterThan(enlarged.height, normal.height)
    }

    @MainActor func testFieldHeightsAndLargerTextGrowInsteadOfClipping() async {
        let add = AddField("Add a task", text: .constant(""), onDictate: {})
        let plain = PerchField("Jot a stray thought", text: .constant(""))
        XCTAssertEqual(Self.measure(add.frame(width: 320)).height, 44, accuracy: 1)
        XCTAssertEqual(Self.measure(plain.frame(width: 320)).height, 38, accuracy: 1)
        let enlarged = Self.measure(add.frame(width: 320).environment(\.dynamicTypeSize, .accessibility3))
        XCTAssertGreaterThan(enlarged.height, 44)
        XCTAssertGreaterThanOrEqual(StatusLabel.pointSize(for: .xSmall), 12)
    }

    @MainActor func testCaptureHasNamedFieldReturnActionAndSeparateDictationTarget() async throws {
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        let state = EntryState()
        let host = NSHostingView(rootView: EntryHarness(state: state).environment(\.accessibilityEnabled, true))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer {
            window.close()
            app.setActivationPolicy(originalPolicy)
        }
        let nodes = try await Self.readyNodes(in: window) { candidates in
            guard let cell = Self.captureField(in: candidates)?.cell else { return false }
            return Self.attribute(cell, "accessibilityLabel") as? String == "Add a task"
                && candidates.contains {
                    Self.attribute($0, "accessibilityRole") as? String == "AXButton"
                        && Self.attribute($0, "accessibilityLabel") as? String == "Dictate instead"
                }
        }
        let diagnostics = Self.diagnostics(in: window)
        print("Surface capture inventory:\n\(diagnostics)")
        let field = try XCTUnwrap(Self.captureField(in: nodes), diagnostics)
        // AppKit exposes the cell to accessibility; the ignored backing view owns editing.
        let entry = try XCTUnwrap(field.cell, diagnostics)
        XCTAssertNotNil(entry)
        XCTAssertTrue(nodes.contains { $0 === entry }, "The named cell is in the published AX tree\n\(diagnostics)")
        // A placeholder is only a locator, never a substitute for the accessible name.
        XCTAssertEqual(Self.attribute(entry, "accessibilityRole") as? String, "AXTextField", diagnostics)
        XCTAssertEqual(Self.attribute(entry, "accessibilityLabel") as? String, "Add a task", diagnostics)
        let microphone = try XCTUnwrap(
            nodes.first {
                Self.attribute($0, "accessibilityRole") as? String == "AXButton"
                    && Self.attribute($0, "accessibilityLabel") as? String == "Dictate instead"
            })
        let frame = try XCTUnwrap(microphone.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        XCTAssertGreaterThanOrEqual(frame.width, 28)
        XCTAssertGreaterThanOrEqual(frame.height, 28)
        XCTAssertTrue(field.isEditable)
        XCTAssertTrue(window.makeFirstResponder(field), diagnostics)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, diagnostics)
        XCTAssertTrue(field.currentEditor() === editor, "Typing targets the named field\n\(diagnostics)")
        editor.insertText("A new task", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        let enter = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(enter)
        await Task.yield()
        XCTAssertEqual(state.text, "A new task")
        XCTAssertEqual(state.submissions, 1)
        XCTAssertEqual(state.dictations, 0)
        let action = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(microphone.responds(to: action))
        guard microphone.responds(to: action) else { return }
        typealias Press = @convention(c) (NSObject, Selector) -> Bool
        let press = unsafeBitCast(microphone.method(for: action), to: Press.self)
        XCTAssertTrue(press(microphone, action))
        await Task.yield()
        XCTAssertEqual(state.dictations, 1)
        XCTAssertEqual(state.submissions, 1)
        XCTAssertEqual(state.text, "A new task")
    }

    @MainActor func testRenderedFieldsPublishDistinctNamesInsteadOfPrompts() async throws {
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        let host = NSHostingView(
            rootView: VStack {
                AddField(
                    "Add a task", text: .constant(""), prompt: "Add a task. Tab makes it a step.", onDictate: {})
                PerchField("Jot a stray thought", text: .constant(""), prompt: "Nothing planned yet")
            }.environment(\.accessibilityEnabled, true))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.close()
            app.setActivationPolicy(originalPolicy)
        }
        let expected = ["Add a task", "Jot a stray thought"]
        let nodes = try await Self.readyNodes(in: window) { candidates in
            expected.allSatisfy { label in
                candidates.contains {
                    Self.attribute($0, "accessibilityRole") as? String == "AXTextField"
                        && Self.attribute($0, "accessibilityLabel") as? String == label
                }
            }
        }
        let fields = nodes.filter { Self.attribute($0, "accessibilityRole") as? String == "AXTextField" }
        XCTAssertEqual(fields.count, expected.count, Self.diagnostics(in: window))
        for label in expected {
            XCTAssertEqual(fields.filter { Self.attribute($0, "accessibilityLabel") as? String == label }.count, 1)
        }
    }

    @MainActor func testNativeFieldIdentityNamesTheCellAndPreservesAdjacentControls() throws {
        _ = NSApplication.shared
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 40))
        field.placeholderString = "Add a task. Tab makes it a step."
        field.stringValue = "Keep this draft"
        let neighbor = NSTextField(frame: NSRect(x: 200, y: 0, width: 180, height: 40))
        neighbor.setAccessibilityLabel("Jot a stray thought")
        let microphone = NSButton(frame: NSRect(x: 180, y: 0, width: 28, height: 28))
        microphone.setAccessibilityLabel("Dictate instead")
        let anchor = SurfaceFieldIdentity.Anchor(frame: field.frame)
        let children: [NSView] = [field, neighbor, microphone, anchor]
        for view in children { container.addSubview(view) }
        anchor.label = "Add a task"
        anchor.identifierValue = "capture-add-task"
        anchor.publish()
        let cell = try XCTUnwrap(field.cell)
        XCTAssertEqual(field.accessibilityLabel(), "Add a task")
        XCTAssertEqual(cell.accessibilityLabel(), "Add a task")
        XCTAssertEqual(cell.accessibilityIdentifier(), "capture-add-task")
        XCTAssertEqual(field.stringValue, "Keep this draft")
        XCTAssertEqual(field.placeholderString, "Add a task. Tab makes it a step.")
        XCTAssertEqual(neighbor.accessibilityLabel(), "Jot a stray thought")
        XCTAssertEqual(microphone.accessibilityLabel(), "Dictate instead")
        XCTAssertFalse(anchor.isAccessibilityElement())
        XCTAssertNil(anchor.hitTest(.zero))

        anchor.label = "Jot a stray thought"
        anchor.publish()
        XCTAssertEqual(field.accessibilityLabel(), "Jot a stray thought")
        XCTAssertEqual(cell.accessibilityLabel(), "Jot a stray thought")
        XCTAssertEqual(field.stringValue, "Keep this draft")
    }

    @MainActor func testNativeFieldIdentityRejectsMissingAmbiguousAndNoneditableOwners() {
        _ = NSApplication.shared
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        let first = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 40))
        let second = NSTextField(frame: first.frame)
        let anchor = SurfaceFieldIdentity.Anchor(frame: first.frame)
        anchor.label = "Add a task"
        anchor.identifierValue = "capture-add-task"
        container.addSubview(anchor)
        anchor.publish()
        container.addSubview(first)
        container.addSubview(second)
        anchor.publish()
        XCTAssertNil(first.accessibilityLabel())
        XCTAssertNil(second.accessibilityLabel())
        second.removeFromSuperview()
        first.isEditable = false
        anchor.publish()
        XCTAssertNil(first.accessibilityLabel())
        first.isEditable = true
        anchor.frame.origin.x = 220
        anchor.publish()
        XCTAssertNil(first.accessibilityLabel())
        anchor.frame = .zero
        anchor.publish()
        XCTAssertNil(first.accessibilityLabel())
    }

    @MainActor func testTypedResolverPrefersIdentityAndNeverUsesNoneditableText() {
        let decoration = NSTextField(labelWithString: "Add a task")
        decoration.setAccessibilityIdentifier("capture-add-task")
        let labeled = NSTextField()
        labeled.isEditable = true
        labeled.setAccessibilityLabel("Add a task")
        let identified = NSTextField()
        identified.isEditable = true
        identified.setAccessibilityIdentifier("capture-add-task")
        let placeholder = NSTextField()
        placeholder.isEditable = true
        placeholder.placeholderString = "Add a task. Tab makes it a step."
        XCTAssertTrue(Self.captureField(in: [decoration, labeled, identified, placeholder]) === identified)
        XCTAssertTrue(Self.captureField(in: [decoration, labeled, placeholder]) === labeled)
        XCTAssertTrue(Self.captureField(in: [decoration, placeholder]) === placeholder)
        XCTAssertNil(Self.captureField(in: [decoration]))
        // Locating via a prompt must not manufacture an accessible name.
        XCTAssertNotEqual(Self.attribute(placeholder, "accessibilityLabel") as? String, "Add a task")
    }

    @MainActor func testAccessibilityTextPreservesPlainAndAttributedNames() {
        XCTAssertEqual(Self.accessibilityText("Add a task"), "Add a task")
        XCTAssertEqual(Self.accessibilityText(NSAttributedString(string: "Add a task")), "Add a task")
        XCTAssertEqual(Self.accessibilityText(NSAttributedString(string: "Dictate instead")), "Dictate instead")
        XCTAssertNil(Self.accessibilityText(nil))
        XCTAssertNil(Self.accessibilityText(42))
    }

    @MainActor private static func captureField(in nodes: [NSObject]) -> NSTextField? {
        let fields = nodes.compactMap { $0 as? NSTextField }.filter(\.isEditable)
        if let identified = fields.first(where: { $0.accessibilityIdentifier() == "capture-add-task" }) {
            return identified
        }
        if let labeled = fields.first(where: { $0.accessibilityLabel() == "Add a task" }) {
            return labeled
        }
        return fields.first { $0.placeholderString == "Add a task. Tab makes it a step." }
    }

    private static func accessibilityText(_ value: Any?) -> String? {
        if let attributed = value as? NSAttributedString { return attributed.string }
        return value as? String
    }

    @MainActor private static func readyNodes(
        in window: NSWindow, matching predicate: ([NSObject]) -> Bool
    ) async throws -> [NSObject] {
        for _ in 0..<100 {
            window.contentView?.layoutSubtreeIfNeeded()
            let candidates = nodes(window)
            if predicate(candidates) { return candidates }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Named surface controls did not become ready.\n\(diagnostics(in: window))")
        throw SurfaceTestError.notReady
    }

    @MainActor private static func diagnostics(in window: NSWindow) -> String {
        let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let observed = nodes(window).map { node in
            let native =
                (node as? NSTextField).map {
                    "editable=\($0.isEditable) placeholder=\($0.placeholderString ?? "nil")"
                } ?? ""
            return "\(type(of: node)) role=\(attribute(node, "accessibilityRole") ?? "nil") "
                + "label=\(attribute(node, "accessibilityLabel") ?? "nil") "
                + "title=\(attribute(node, "accessibilityTitle") ?? "nil") "
                + "id=\(attribute(node, "accessibilityIdentifier") ?? "nil") \(native)"
        }.joined(separator: "\n")
        return "key=\(window.isKeyWindow) visible=\(window.isVisible) firstResponder=\(responder)\n\(observed)"
    }

    private enum SurfaceTestError: Error { case notReady }

    @MainActor private static func measure<V: View>(_ view: V) -> CGSize {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.fixedSize())
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @MainActor private final class EntryState: ObservableObject {
        @Published var text = ""
        var submissions = 0
        var dictations = 0
    }

    private struct EntryHarness: View {
        @ObservedObject var state: EntryState
        @FocusState private var focused: Bool

        var body: some View {
            DotGridSheet(.window) {
                AddField(
                    "Add a task", text: $state.text, prompt: "Add a task. Tab makes it a step.", focus: $focused,
                    onSubmit: { state.submissions += 1 }, onDictate: { state.dictations += 1 })
            }
            .task { focused = true }
        }
    }

    @MainActor private static func attribute(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard node.responds(to: selector) else { return nil }
        let value = node.perform(selector)?.takeUnretainedValue()
        if let text = accessibilityText(value) { return text }
        return value
    }

    @MainActor private static func nodes(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        @MainActor func walk(_ node: NSObject, _ depth: Int) -> [NSObject] {
            guard depth < 60, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            var children = ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"]
                .flatMap { (attribute(node, $0) as? [NSObject]) ?? [] }
            // Ignored hosting views can expose descendants only through the native hierarchy.
            if let view = node as? NSView { children += view.subviews }
            if let window = node as? NSWindow, let content = window.contentView { children.append(content) }
            return [node] + children.flatMap { walk($0, depth + 1) }
        }
        return walk(root, 0)
    }
}
