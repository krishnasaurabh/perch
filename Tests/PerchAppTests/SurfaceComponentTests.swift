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
        for _ in 0..<50 {
            host.layoutSubtreeIfNeeded()
            if window.firstResponder is NSTextView { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let nodes = Self.nodes(window)
        let entry = try XCTUnwrap(
            nodes.first {
                Self.attribute($0, "accessibilityRole") as? String == "AXTextField"
                    && Self.attribute($0, "accessibilityLabel") as? String == "Add a task"
            })
        XCTAssertNotNil(entry)
        let microphone = try XCTUnwrap(
            nodes.first {
                Self.attribute($0, "accessibilityRole") as? String == "AXButton"
                    && Self.attribute($0, "accessibilityLabel") as? String == "Dictate instead"
            })
        let frame = try XCTUnwrap(microphone.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        XCTAssertGreaterThanOrEqual(frame.width, 28)
        XCTAssertGreaterThanOrEqual(frame.height, 28)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
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
        return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
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
