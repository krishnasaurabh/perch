import AppKit
import PerchUI
import PlannerCore
import SwiftUI
import XCTest
@testable import PerchApp

/// Exercise the production page with native key events, not AX press or a model action.
final class WeekInboxKeyboardTests: XCTestCase {
    @MainActor
    func testInboxIsInNativeTabLoopAndTogglesFromKeyboard() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = PlannerStore(file: file, now: { now }, watching: false)
        let task = try XCTUnwrap(store.addTasks(["Keyboard week task"], on: .day(store.today))?.first)
        XCTAssertNotNil(store.addTasks(["Keyboard inbox task"], on: .inbox))
        let model = NotchModel(motionPolicy: MotionPolicy(reduceMotion: true))
        model.page = .week
        let before = NSTextField(string: "Before week")
        let after = NSTextField(string: "After week")
        let host = NSHostingView(
            rootView: VStack {
                WeekKeyboardField(field: before)
                WeekPage().frame(width: 820, height: 420)
                WeekKeyboardField(field: after)
            }
            .environmentObject(store).environmentObject(model)
            .environment(\.accessibilityEnabled, true)
            .environment(\.colorScheme, .dark)
            .environment(\.motionPolicyOverride, MotionPolicy(reduceMotion: true)))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 520),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(NSSize(width: 880, height: 520))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        await Self.settle()
        XCTAssertTrue(window.isKeyWindow, "Native traversal requires the real key window")
        let inbox = try Self.control("week-inbox", in: window)
        XCTAssertEqual(Self.string(inbox, "accessibilityRole"), "AXButton")
        XCTAssertEqual(Self.string(inbox, "accessibilityLabel"), "Inbox (1)")
        XCTAssertEqual(
            Self.string(inbox, "accessibilityHelp"), "Open Inbox, or drop a task here to unschedule it.")
        let bounds = Self.frame(inbox)
        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertGreaterThan(bounds.height, 0)
        XCTAssertTrue(window.convertToScreen(host.frame).contains(bounds), "Inbox must be visible")
        try Self.capture(host, name: "week-inbox-before")
        let tasksBefore = try file.load().tasks
        XCTAssertTrue(window.makeFirstResponder(before))

        // Keep the full cycle for sibling diagnostics, even after visiting the Inbox.
        var visited = Set<String>()
        var sawEditor = false
        for index in 0..<28 {
            try await Self.key(window, code: 48, characters: "\t")
            let focused = Self.nodes(window).filter { Self.boolean($0, "isAccessibilityFocused") == true }
            visited.formUnion(focused.compactMap { Self.string($0, "accessibilityIdentifier") })
            sawEditor = sawEditor || window.firstResponder is NSTextView
            Self.trace(window, tag: "Tab \(index)")
        }
        XCTAssertTrue(sawEditor, "Real Tab events must reach a native editor")
        XCTAssertTrue(visited.contains("week-menu-\(task.id)"), "The existing task menu is a positive control")
        guard visited.contains("week-inbox") else {
            XCTFail("Real Tab traversal skipped the visible week-inbox control; visited=\(visited.sorted())")
            return
        }
        XCTAssertEqual(try file.load().tasks, tasksBefore, "Traversal alone must never edit tasks")

        try await Self.tabToInbox(window)
        try Self.capture(host, name: "week-inbox-focused")
        try await Self.key(window, code: 49, characters: " ")
        XCTAssertEqual(Self.string(try Self.control("week-inbox", in: window), "accessibilityLabel"), "Back to week")
        XCTAssertEqual(
            Self.string(try Self.control("week-inbox", in: window), "accessibilityHelp"),
            "Drag here to reveal the week, then drop onto a day.")
        XCTAssertTrue(Self.nodes(window).contains { Self.string($0, "accessibilityLabel") == "Add to Inbox" })
        try await Self.key(window, code: 49, characters: " ")
        XCTAssertEqual(Self.string(try Self.control("week-inbox", in: window), "accessibilityLabel"), "Inbox (1)")
        try await Self.key(window, code: 48, characters: "\t")
        XCTAssertFalse(Self.boolean(try Self.control("week-inbox", in: window), "isAccessibilityFocused") == true)
        try await Self.key(window, code: 48, characters: "\u{19}", modifiers: .shift)
        XCTAssertEqual(Self.boolean(try Self.control("week-inbox", in: window), "isAccessibilityFocused"), true)

        let shortcut = try Self.event(
            window, code: 34, characters: "i", type: .keyDown, modifiers: [.command, .option])
        XCTAssertTrue(window.performKeyEquivalent(with: shortcut), "Command-Option-I remains handled")
        await Self.settle()
        XCTAssertEqual(Self.string(try Self.control("week-inbox", in: window), "accessibilityLabel"), "Back to week")
        XCTAssertEqual(try file.load().tasks, tasksBefore, "Inbox navigation preserves every persisted task")
        Self.log("PASS: Week Inbox native Tab, Space, back-tab and Command-Option-I")
    }

    @MainActor private static func tabToInbox(_ window: NSWindow) async throws {
        for _ in 0..<28 {
            if boolean(try control("week-inbox", in: window), "isAccessibilityFocused") == true { return }
            try await key(window, code: 48, characters: "\t")
        }
        XCTFail("Inbox left the native key loop after traversal")
        throw WeekKeyboardError.missingControl
    }

    @MainActor private static func event(
        _ window: NSWindow, code: UInt16, characters: String, type: NSEvent.EventType,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code))
    }

    @MainActor private static func key(
        _ window: NSWindow, code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []
    ) async throws {
        XCTAssertTrue(window.isKeyWindow)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            NSApp.sendEvent(try event(window, code: code, characters: characters, type: type, modifiers: modifiers))
        }
        await settle()
    }

    @MainActor private static func settle() async {
        try? await Task.sleep(for: .milliseconds(200))
        NSApp.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
    }

    @MainActor private static func control(_ identifier: String, in window: NSWindow) throws -> NSObject {
        let matches = nodes(window).filter { string($0, "accessibilityIdentifier") == identifier }
        XCTAssertEqual(matches.count, 1, "Exactly one native control must own \(identifier)")
        return try XCTUnwrap(matches.first)
    }

    @MainActor private static func value(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
    }

    @MainActor private static func string(_ node: NSObject, _ name: String) -> String? {
        value(node, name) as? String
    }

    @MainActor private static func boolean(_ node: NSObject, _ name: String) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard node.responds(to: selector), let implementation = node.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(implementation, to: Getter.self)(node, selector)
    }

    @MainActor private static func frame(_ node: NSObject) -> NSRect {
        guard node.responds(to: NSSelectorFromString("accessibilityFrame")),
            let frame = node.value(forKey: "accessibilityFrame") as? NSValue
        else { return .zero }
        return frame.rectValue
    }

    @MainActor private static func nodes(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        var retained: [NSObject] = []
        @MainActor func walk(_ node: NSObject, depth: Int) {
            guard depth < 40, retained.count < 3000, seen.insert(ObjectIdentifier(node)).inserted else { return }
            retained.append(node)
            var children = ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"]
                .flatMap { value(node, $0) as? [NSObject] ?? [] }
            if let view = node as? NSView { children += view.subviews }
            if let window = node as? NSWindow, let content = window.contentView { children.append(content) }
            for child in children { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return retained
    }

    @MainActor private static func trace(_ window: NSWindow, tag: String) {
        let focused = nodes(window).filter { boolean($0, "isAccessibilityFocused") == true }.map {
            "\(type(of: $0)) id=\(string($0, "accessibilityIdentifier") ?? "nil") "
                + "role=\(string($0, "accessibilityRole") ?? "nil") "
                + "label=\(string($0, "accessibilityLabel") ?? "nil")"
        }
        log(
            "Week \(tag): key=\(window.isKeyWindow) responder=\(String(describing: window.firstResponder)) focused=\(focused)"
        )
    }

    @MainActor private static func capture(_ host: NSView, name: String) throws {
        guard let runner = ProcessInfo.processInfo.environment["RUNNER_TEMP"] else { return }
        let directory = URL(fileURLWithPath: runner).appendingPathComponent("native-diagnostics/week-inbox")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("\(name).png"))
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}

private enum WeekKeyboardError: Error { case missingControl }

private struct WeekKeyboardField: NSViewRepresentable {
    let field: NSTextField
    func makeNSView(context: Context) -> NSTextField { field }
    func updateNSView(_ view: NSTextField, context: Context) {}
}
