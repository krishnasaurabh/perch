import AppKit
import PerchUI
import PlannerCore
import SwiftUI
import XCTest
@testable import PerchApp

final class DateFieldEditorTests: XCTestCase {
    @MainActor private func editor(_ draft: DateFieldDraft, actions: Bool) -> some View {
        DateFieldEditor(
            field: "Deadline", draft: .constant(draft),
            onCommit: actions ? { _ in } : nil, onCancel: actions ? {} : nil
        )
        .environment(\.locale, Locale(identifier: "en_US"))
    }

    @MainActor
    func testRequiredNoneExplainsDisabledApplyAndCommitsOnlyAfterSelection() async throws {
        let state = DateEditorTestState()
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 320, height: 180),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: DateEditorTestHost(state: state).environment(\.accessibilityEnabled, true))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer {
            window.close()
            app.setActivationPolicy(originalPolicy)
        }

        let issue = try await Self.control("deadline-date-issue", in: window)
        XCTAssertEqual(Self.attribute(issue, "accessibilityLabel") as? String, "Choose a date.")
        let apply = try await Self.control("deadline-date-commit", in: window)
        XCTAssertFalse(try Self.isEnabled(apply))
        XCTAssertEqual(state.draft.entry, .none)
        XCTAssertTrue(state.commits.isEmpty)

        // Use the actual Add control; do not call draft methods to bypass the editor.
        try Self.press(try await Self.control("deadline-date-add", in: window))
        let enabledApply = try await Self.control("deadline-date-commit", in: window)
        XCTAssertTrue(try Self.isEnabled(enabledApply))
        XCTAssertEqual(state.draft.entry, .day("2026-11-09"))
        XCTAssertFalse(
            Self.nodes(window).contains {
                Self.attribute($0, "accessibilityIdentifier") as? String == "deadline-date-issue"
            })
        XCTAssertTrue(state.commits.isEmpty, "Choosing a date edits the draft, not the model")

        try Self.press(try await Self.control("deadline-date-clear", in: window))
        _ = try await Self.control("deadline-date-issue", in: window)
        let clearedApply = try await Self.control("deadline-date-commit", in: window)
        XCTAssertFalse(try Self.isEnabled(clearedApply))
        XCTAssertTrue(state.commits.isEmpty)

        try Self.press(try await Self.control("deadline-date-add", in: window))
        try Self.press(try await Self.control("deadline-date-commit", in: window))
        XCTAssertEqual(state.commits, [.set("2026-11-09")])
        XCTAssertNil(state.draft.original)
    }

    @MainActor
    private static func control(_ identifier: String, in window: NSWindow) async throws -> NSObject {
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 50_000_000)
            window.contentView?.layoutSubtreeIfNeeded()
            if let node = nodes(window).first(where: {
                attribute($0, "accessibilityIdentifier") as? String == identifier
            }) {
                return node
            }
        }
        let observed = nodes(window).map {
            "\(type(of: $0)) id=\(attribute($0, "accessibilityIdentifier") ?? "nil") "
                + "label=\(attribute($0, "accessibilityLabel") ?? "nil") "
                + "accessibilityAttributeNames=\(attribute($0, "accessibilityAttributeNames") ?? "unavailable")"
        }.joined(separator: "\n")
        XCTFail("Missing \(identifier); observed:\n\(observed)")
        throw DateEditorTestError.missingControl
    }

    @MainActor
    private static func isEnabled(_ node: NSObject) throws -> Bool {
        if let button = node as? NSButton { return button.isEnabled }
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        let implementation = try XCTUnwrap(node.responds(to: selector) ? node.method(for: selector) : nil)
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(implementation, to: Getter.self)(node, selector)
    }

    @MainActor
    private static func press(_ node: NSObject) throws {
        XCTAssertTrue(try isEnabled(node))
        if let button = node as? NSButton {
            button.performClick(nil)
        } else {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            let implementation = try XCTUnwrap(node.responds(to: selector) ? node.method(for: selector) : nil)
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            XCTAssertTrue(unsafeBitCast(implementation, to: Press.self)(node, selector))
        }
    }

    @MainActor
    private static func attribute(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
    }

    @MainActor
    private static func nodes(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        @MainActor func walk(_ node: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            var children = ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"]
                .flatMap { (attribute(node, $0) as? [NSObject]) ?? [] }
            if let view = node as? NSView { children += view.subviews }
            if let window = node as? NSWindow, let content = window.contentView { children.append(content) }
            return [node] + children.flatMap(walk)
        }
        return walk(root)
    }

    /// Every state stays inside a narrow column instead of clipping its controls.
    @MainActor func testEditorFitsNarrowWidthsInEveryState() {
        var invalid = DateFieldDraft(original: "2026-11-20", today: "2026-11-09", requirement: .required)
        invalid.type("not a day")
        var cleared = DateFieldDraft(original: "2026-11-20", today: "2026-11-09", requirement: .required)
        cleared.clear()
        let states = [
            DateFieldDraft(original: nil, today: "2026-11-09"),
            DateFieldDraft(original: nil, today: "2026-11-09", requirement: .required),
            DateFieldDraft(original: "2026-11-20", today: "2026-11-09"),
            DateFieldDraft(original: "2026-10-01", today: "2026-11-09"),
            invalid, cleared,
        ]
        for width in [220.0, 320, 460] {
            for draft in states {
                for actions in [true, false] {
                    let host = NSHostingController(rootView: editor(draft, actions: actions))
                    let size = host.sizeThatFits(in: CGSize(width: width, height: 10_000))
                    XCTAssertLessThanOrEqual(size.width, width, "\(draft.entry) actions=\(actions) at \(width)")
                    XCTAssertGreaterThan(size.height, 0)
                }
            }
        }
    }
}

private enum DateEditorTestError: Error { case missingControl }

@MainActor
private final class DateEditorTestState: ObservableObject {
    @Published var draft = DateFieldDraft(original: nil, today: "2026-11-09", requirement: .required)
    var commits: [DateFieldDraft.Commit] = []
}

@MainActor
private struct DateEditorTestHost: View {
    @ObservedObject var state: DateEditorTestState

    var body: some View {
        DateFieldEditor(
            field: "Deadline", draft: $state.draft,
            onCommit: { state.commits.append($0) }, onCancel: {})
    }
}
