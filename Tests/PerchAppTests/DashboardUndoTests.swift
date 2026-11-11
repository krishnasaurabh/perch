import AppKit
import SwiftUI
import XCTest
@testable import PerchApp
@testable import PlannerCore

@MainActor
final class DashboardUndoTests: XCTestCase {
    func testCommandZRestoresDeletedProjectExactlyOnce() async throws {
        let fixture = try DashboardFixture()
        defer { fixture.close() }
        let window = try await fixture.open(tab: "Projects")
        let beforeDelete = fixture.store.planner
        let projectID = try XCTUnwrap(beforeDelete.projects.first?.id)

        try Self.press(try await Self.control(named: "Delete project", in: window))
        await Self.settle()
        let deleted = try fixture.file.load()
        XCTAssertTrue(deleted.projects.isEmpty)
        XCTAssertTrue(deleted.tasks.allSatisfy { $0.projectID == nil })
        XCTAssertNotEqual(deleted, beforeDelete)
        XCTAssertTrue(window.isKeyWindow, "Command-Z is dispatched to the real Dashboard key window")

        XCTAssertTrue(window.performKeyEquivalent(with: Self.commandZ(windowNumber: window.windowNumber)))
        await Self.settle()
        XCTAssertEqual(
            try fixture.file.load(), beforeDelete, "Command-Z restores the exact persisted project and tasks")
        XCTAssertEqual(fixture.store.planner, beforeDelete)
        XCTAssertTrue(fixture.store.canRedo, "One key press consumes exactly one planner Undo entry")
        XCTAssertEqual(fixture.store.planner.tasks.map(\.notes), beforeDelete.tasks.map(\.notes))
        XCTAssertEqual(projectID, beforeDelete.projects[0].id)
    }

    func testCommandZInDashboardTextFieldUsesNativeUndo() async throws {
        let fixture = try DashboardFixture()
        defer { fixture.close() }
        let window = try await fixture.open(tab: "History")
        let beforeEditing = try fixture.file.load()
        let field = try XCTUnwrap(
            try await Self.control(named: "Search history", role: .textField, in: window) as? NSTextField)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertTrue(editor.allowsUndo)

        editor.insertText("first", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.breakUndoCoalescing()
        editor.insertText(" second", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        editor.breakUndoCoalescing()
        XCTAssertEqual(editor.string, "first second")
        XCTAssertTrue(editor.undoManager?.canUndo == true, "The real field editor registered native text Undo")

        XCTAssertTrue(window.performKeyEquivalent(with: Self.commandZ(windowNumber: window.windowNumber)))
        await Self.settle()
        XCTAssertEqual(editor.string, "first", "Command-Z edits only the native text-field history")
        XCTAssertEqual(try fixture.file.load(), beforeEditing, "Text Undo never consumes or rewrites planner state")
        XCTAssertTrue(fixture.store.canUndo, "The earlier planner edit remains available for planner Undo")
    }
}

@MainActor
fileprivate extension DashboardUndoTests {
    static func commandZ(windowNumber: Int) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber, context: nil,
            characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
    }

    static func settle() async { try? await Task.sleep(nanoseconds: 100_000_000) }

    enum ControlRole { case button, textField }

    static func control(named name: String, role: ControlRole = .button, in window: NSWindow) async throws -> NSObject {
        for _ in 0..<30 {
            window.contentView?.layoutSubtreeIfNeeded()
            await settle()
            let candidates = nodes(window)
            switch role {
            case .button:
                if let button = candidates.compactMap({ $0 as? NSButton }).first(where: {
                    $0.isEnabled && ($0.title == name || $0.accessibilityLabel() == name)
                }) {
                    return button
                }
                if let node = candidates.first(where: {
                    attribute($0, "accessibilityRole") as? String == "AXButton"
                        && (attribute($0, "accessibilityLabel") as? String == name
                            || attribute($0, "accessibilityTitle") as? String == name)
                }) {
                    return node
                }
            case .textField:
                if let field = candidates.compactMap({ $0 as? NSTextField }).first(where: {
                    $0.isEditable && $0.placeholderString == name
                }) {
                    return field
                }
            }
        }
        let diagnostics = nodes(window).map { node in
            "\(type(of: node)) role=\(attribute(node, "accessibilityRole") ?? "?") "
                + "label=\(attribute(node, "accessibilityLabel") ?? "?") "
                + "title=\((node as? NSButton)?.title ?? "?") "
                + "placeholder=\((node as? NSTextField)?.placeholderString ?? "?")"
        }.joined(separator: "\n")
        XCTFail("Missing Dashboard control \(name):\n\(diagnostics)")
        throw DashboardTestError.missingControl
    }

    static func press(_ node: NSObject) throws {
        if let button = node as? NSButton {
            XCTAssertTrue(button.isEnabled)
            button.performClick(nil)
            return
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let implementation = try XCTUnwrap(node.responds(to: selector) ? node.method(for: selector) : nil)
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(implementation, to: Press.self)(node, selector))
    }

    static func select(tab: String, in window: NSWindow) async throws {
        for _ in 0..<30 {
            window.contentView?.layoutSubtreeIfNeeded()
            await settle()
            if let picker = nodes(window).compactMap({ $0 as? NSSegmentedControl }).first(where: { control in
                (0..<control.segmentCount).contains { index in pickerLabel(control, segment: index) == tab }
            }) {
                let index = try XCTUnwrap((0..<picker.segmentCount).first { pickerLabel(picker, segment: $0) == tab })
                picker.selectedSegment = index
                XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
                await settle()
                return
            }
        }
        XCTFail("Missing Dashboard tab \(tab)")
        throw DashboardTestError.missingControl
    }

    static func pickerLabel(_ picker: NSSegmentedControl, segment: Int) -> String? {
        if #available(macOS 13.0, *) { return picker.label(forSegment: segment) }
        return nil
    }

    static func attribute(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
    }

    static func nodes(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        @MainActor func walk(_ node: NSObject, _ depth: Int) -> [NSObject] {
            guard depth < 60, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            var children = ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"]
                .flatMap { (attribute(node, $0) as? [NSObject]) ?? [] }
            if let view = node as? NSView { children += view.subviews }
            if let window = node as? NSWindow, let content = window.contentView { children.append(content) }
            return [node] + children.flatMap { walk($0, depth + 1) }
        }
        return walk(root, 0)
    }
}

private enum DashboardTestError: Error { case missingControl }

@MainActor
private final class DashboardFixture {
    let directory: URL
    let file: PlannerFile
    let store: PlannerStore
    private let activationPolicy = NSApplication.shared.activationPolicy()
    private var model: NotchModel?
    private var services: Services?

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        file = PlannerFile(url: directory.appendingPathComponent("planner.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = DayKey(now)
        let project = TaskProject(name: "Synthetic project")
        var planner = Planner()
        planner.preferences.resetHour = 0
        planner.projects = [project]
        planner.tasks = [
            PlanTask(title: "Open synthetic task", day: day, createdAt: now, projectID: project.id),
            PlanTask(title: "Finished synthetic task", day: day, done: true, createdAt: now, projectID: project.id),
        ]
        try file.save(planner)
        store = PlannerStore(file: file, now: { now }, watching: false)
        // Leave an earlier Undo entry. A double invocation would revert this edit as well.
        store.updateTask(planner.tasks[0].id) { $0.notes = "Earlier planner edit" }
        NSApp.setActivationPolicy(.accessory)
    }

    func open(tab: String) async throws -> NSWindow {
        let model = NotchModel()
        let services = Services(store: store)
        self.model = model
        self.services = services
        DashboardWindow.show(store: store, model: model, services: services)
        let window = try XCTUnwrap(WindowHost.windows["dashboard"])
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await DashboardUndoTests.select(tab: tab, in: window)
        return window
    }

    func close() {
        WindowHost.windows["dashboard"]?.close()
        WindowHost.windows.removeValue(forKey: "dashboard")
        NSApp.setActivationPolicy(activationPolicy)
        try? FileManager.default.removeItem(at: directory)
    }
}
