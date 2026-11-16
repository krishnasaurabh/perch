import AppKit
import SwiftUI
import XCTest
@testable import PerchApp
@testable import PlannerCore

@MainActor
final class HistorySearchTests: XCTestCase {
    func testRealKeysPublishSearchWithoutReturn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PlannerFile(url: directory.appendingPathComponent("planner.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = DayKey(now)
        var planner = Planner()
        planner.preferences.resetHour = 0
        planner.tasks = [
            PlanTask(title: "History search alpha", day: day, done: true, createdAt: now),
            PlanTask(title: "History search beta", day: day, done: true, createdAt: now),
        ]
        try file.save(planner)
        let store = PlannerStore(file: file, now: { now }, watching: false)
        let policy = NSApplication.shared.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer {
            WindowHost.windows["dashboard"]?.close()
            NSApp.setActivationPolicy(policy)
        }
        DashboardWindow.show(store: store, tab: .history)
        let window = try XCTUnwrap(WindowHost.windows["dashboard"])
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        let field = try XCTUnwrap(
            Self.views(try XCTUnwrap(window.contentView)).compactMap { $0 as? DashboardSearchField }.first)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === editor)
        let beforeEditing = try file.load()
        for character in "History search alpha".map(String.init) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = try XCTUnwrap(
                    NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: character == "H" ? .shift : [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: character, charactersIgnoringModifiers: character,
                        isARepeat: false, keyCode: 0))
                NSApp.sendEvent(event)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            window.contentView?.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(editor.string, "History search alpha")
        XCTAssertEqual(field.stringValue, "History search alpha")
        try await Task.sleep(nanoseconds: 200_000_000)
        window.contentView?.layoutSubtreeIfNeeded()
        for node in Self.nodes(window) {
            let role = Self.attribute(node, "accessibilityRole") as? String ?? ""
            let label = Self.attribute(node, "accessibilityLabel") as? String ?? ""
            let value = Self.attribute(node, "accessibilityValue") as? String ?? ""
            if label.contains("History search") || value.contains("History search") {
                print("History search native node: class=\(type(of: node)) role=\(role) label=\(label) value=\(value)")
            }
        }
        XCTAssertEqual(try file.load(), beforeEditing, "Search must not mutate the planner")
    }

    private static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    private static func attribute(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
    }

    private static func nodes(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        @MainActor func walk(_ node: NSObject, _ depth: Int) -> [NSObject] {
            guard depth < 40, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            var children = ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"]
                .flatMap { (attribute(node, $0) as? [NSObject]) ?? [] }
            if let label = attribute(node, "accessibilityTitleUIElement") as? NSObject { children.append(label) }
            if let view = node as? NSView { children += view.subviews }
            if let window = node as? NSWindow, let content = window.contentView { children.append(content) }
            return [node] + children.flatMap { walk($0, depth + 1) }
        }
        return walk(root, 0)
    }
}
