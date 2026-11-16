import AppKit
import SwiftUI
import XCTest
@testable import PerchApp
@testable import PlannerCore

@MainActor
final class DashboardUndoTests: XCTestCase {
    func testThreeTabsReuseTheSameWindowAndHonorEveryOpenRequest() async throws {
        XCTAssertEqual(DashboardView.Tab.allCases.map(\.rawValue), ["This week", "History", "Projects"])
        let fixture = try DashboardFixture()
        defer { fixture.close() }
        let window = try await fixture.open(tab: "This week")
        let selection = try XCTUnwrap(DashboardWindow.selection)
        for tab in DashboardView.Tab.allCases + [.history, .yourWeek] {
            DashboardWindow.show(store: fixture.store, tab: tab)
            await Self.settle()
            XCTAssertTrue(WindowHost.windows["dashboard"] === window)
            XCTAssertTrue(DashboardWindow.selection === selection)
            XCTAssertEqual(selection.tab, tab)
        }
        XCTAssertEqual(DashboardView.Tab.history.heading, "Looking back")
    }

    func testMoreMenuRoutesToEachTabAndPreservesOtherActions() async throws {
        let fixture = try DashboardFixture()
        defer { fixture.close() }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let undo = NSMenuItem(title: "Undo", action: nil, keyEquivalent: "")
        undo.isEnabled = false
        let settings = NSMenuItem(title: "Settings…", action: nil, keyEquivalent: "")
        menu.addItem(undo)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Dashboard", action: nil, keyEquivalent: ""))
        menu.addItem(settings)
        var opened = 0
        DashboardWindow.installMenuItems(in: menu) {
            opened += 1
            DashboardWindow.show(store: fixture.store)
        }
        XCTAssertEqual(menu.items.map(\.title), ["Undo", "", "Your week", "History", "Projects", "Settings…"])
        XCTAssertTrue(menu.items.first === undo)
        XCTAssertFalse(undo.isEnabled)
        XCTAssertTrue(menu.items.last === settings)
        for (index, tab) in DashboardView.Tab.allCases.enumerated() {
            let item = menu.items[index + 2]
            XCTAssertTrue(item.isEnabled)
            XCTAssertNotNil(item.representedObject, "The native menu retains each action target")
            let action = try XCTUnwrap(item.action)
            XCTAssertEqual(NSStringFromSelector(action), "chooseTab:", "Do not select NSObject.perform(_:)")
            XCTAssertTrue(try XCTUnwrap(item.target as? NSObject).responds(to: action))
            XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
            await Self.settle()
            XCTAssertEqual(DashboardWindow.selection?.tab, tab)
            XCTAssertEqual(opened, index + 1)
        }
    }

    func testCommandZRestoresDeletedProjectExactlyOnce() async throws {
        let fixture = try DashboardFixture()
        defer { fixture.close() }
        let window = try await fixture.open(tab: "Projects")
        let beforeDelete = fixture.store.planner
        let projectID = try XCTUnwrap(beforeDelete.projects.first?.id)
        print("Dashboard Projects model: \(beforeDelete.projects.map(\.name))")

        // Delete through the card's own visible options control, never a hidden
        // button and never a direct model call.
        let options = try await Self.control(named: "Project options", in: window)
        try Self.press(options)
        await Self.settle()
        let optionsWindow = try await Self.popover(besides: window, offering: "Delete project")
        let delete = try await Self.control(named: "Delete project", in: optionsWindow)
        try Self.press(delete)
        await Self.settle()
        let deleted = try fixture.file.load()
        XCTAssertTrue(deleted.projects.isEmpty)
        XCTAssertTrue(deleted.tasks.allSatisfy { $0.projectID == nil })
        XCTAssertNotEqual(deleted, beforeDelete)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await Self.settle()
        print("Dashboard key-window request accepted: \(window.isKeyWindow)")

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
        let fieldNode = try await Self.control(named: "Find a finished task", role: .textField, in: window)
        let field = try XCTUnwrap(fieldNode as? NSTextField)
        XCTAssertEqual(field.identifier?.rawValue, "dashboard-history-search", "The native search keeps its identifier")
        XCTAssertEqual(
            field.accessibilityLabel(), "Find a finished task", "The search is labelled for its finished rows")
        // History lists finished tasks only, so the open task never reaches the list.
        print("Dashboard History model: \(fixture.store.planner.tasks.filter(\.done).map(\.title))")
        let texts = Self.nodes(window).flatMap { node -> [String] in
            guard Self.attribute(node, "accessibilityRole") as? String == "AXStaticText" else { return [] }
            return ["accessibilityLabel", "accessibilityValue"].compactMap { Self.attribute(node, $0) as? String }
        }
        XCTAssertTrue(texts.contains("Finished synthetic task"), "History lists the finished task")
        XCTAssertFalse(texts.contains("Open synthetic task"), "History never lists an open task")
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        fixture.undoTarget.editor = editor
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertTrue(editor.allowsUndo)

        editor.insertText("first second", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.breakUndoCoalescing()
        XCTAssertEqual(editor.string, "first second")
        XCTAssertTrue(editor.undoManager?.canUndo == true, "The real field editor registered native text Undo")

        NSApp.sendEvent(Self.commandZ(windowNumber: window.windowNumber))
        await Self.settle()
        XCTAssertEqual(editor.string, "", "Command-Z edits only the native text-field history")
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

    /// The card's options surface is its own native window, so the visible
    /// control and the actions it reveals are both exercised as a person sees them.
    static func popover(besides window: NSWindow, offering name: String) async throws -> NSWindow {
        for _ in 0..<30 {
            await settle()
            let candidates = NSApp.windows.filter {
                $0 !== window && $0.isVisible && $0.contentView != nil && $0.attachedSheet == nil
                    && nodes($0).contains { node in
                        (node as? NSButton)?.title == name || attribute(node, "accessibilityLabel") as? String == name
                    }
            }
            if let candidate = candidates.first { return candidate }
        }
        XCTFail("Missing project options surface offering \(name)")
        throw DashboardTestError.missingControl
    }

    /// Perform a menu item's own target/action, the dispatch a click performs.
    static func chooseMenuItem(named title: String, in menu: NSMenu) -> Bool {
        guard let item = menu.items.first(where: { $0.title == title }), item.isEnabled,
            let action = item.action, let target = item.target
        else { return false }
        return NSApp.sendAction(action, to: target, from: item)
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
private final class DashboardUndoTarget: NSObject {
    weak var editor: NSTextView?
    @objc func undo(_ sender: Any?) { editor?.undoManager?.undo() }
}

@MainActor
private final class DashboardFixture {
    let directory: URL
    let file: PlannerFile
    let store: PlannerStore
    private let activationPolicy = NSApplication.shared.activationPolicy()
    private let previousMainMenu = NSApplication.shared.mainMenu
    let undoTarget = DashboardUndoTarget()

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
        NSApp.setActivationPolicy(.regular)
        let mainMenu = NSMenu()
        let editRoot = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        let undoItem = editMenu.addItem(
            withTitle: "Undo", action: #selector(DashboardUndoTarget.undo(_:)), keyEquivalent: "z")
        undoItem.target = undoTarget
        mainMenu.addItem(editRoot)
        mainMenu.setSubmenu(editMenu, for: editRoot)
        NSApp.mainMenu = mainMenu
    }

    func open(tab: String) async throws -> NSWindow {
        DashboardWindow.show(store: store, tab: try XCTUnwrap(DashboardView.Tab(rawValue: tab)))
        let window = try XCTUnwrap(WindowHost.windows["dashboard"])
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await DashboardUndoTests.settle()
        return window
    }

    func close() {
        WindowHost.windows["dashboard"]?.close()
        WindowHost.windows.removeValue(forKey: "dashboard")
        NSApp.mainMenu = previousMainMenu
        NSApp.setActivationPolicy(activationPolicy)
        try? FileManager.default.removeItem(at: directory)
    }
}
