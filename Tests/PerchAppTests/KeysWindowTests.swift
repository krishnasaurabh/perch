import AppKit
import PerchUI
import SwiftUI
import XCTest

@testable import PerchApp
@testable import PlannerCore

final class KeysWindowTests: XCTestCase {
    @MainActor
    func testEveryDeclaredHandlerIsInstalledInTheProductionRouter() async throws {
        let fixture = try KeysFixture()
        defer { fixture.cleanUp() }
        let router = KeysShortcutRouter(store: fixture.store, model: NotchModel())
        XCTAssertTrue(router.bindings.unboundEntries.isEmpty)
        XCTAssertEqual(Set(KeyMap.boundEntries.compactMap(\.handler)), Set(KeyMap.Handler.allCases))
    }

    @MainActor
    func testProductionBindingsChangeTheTimerAndUndoTaskEdits() async throws {
        let fixture = try KeysFixture()
        defer { fixture.cleanUp() }
        let model = NotchModel()
        let router = KeysShortcutRouter(store: fixture.store, model: model)
        let task = try XCTUnwrap(
            fixture.store.addTasks(["Write the outline"], on: .day(fixture.store.today), literal: true)?.first)
        XCTAssertNotNil(fixture.store.send(.startTimer(task.id, minutes: 25)))
        XCTAssertTrue(perform(.pauseOrContinue, with: router))
        XCTAssertEqual(fixture.store.planner.focus?.state, .paused)
        XCTAssertTrue(perform(.pauseOrContinue, with: router))
        XCTAssertEqual(fixture.store.planner.focus?.state, .running)
        let previousLimit = try XCTUnwrap(fixture.store.planner.focus?.limit)
        XCTAssertTrue(perform(.addFiveMinutes, with: router))
        XCTAssertEqual(fixture.store.planner.focus?.limit, previousLimit + 300)
        let later = try XCTUnwrap(
            fixture.store.addTasks(["Check the draft"], on: .day(fixture.store.today), literal: true)?.first)
        XCTAssertTrue(perform(.undo, with: router))
        XCTAssertFalse(fixture.store.planner.tasks.contains { $0.id == later.id })
        // Undo restores task edits, not the runtime clock.
        XCTAssertEqual(fixture.store.planner.focus?.limit, previousLimit + 300)
    }

    @MainActor
    func testInactiveTimerBindingsDoNotConsumeTheKey() async throws {
        let fixture = try KeysFixture()
        defer { fixture.cleanUp() }
        let router = KeysShortcutRouter(store: fixture.store, model: NotchModel())
        XCTAssertFalse(perform(.pauseOrContinue, with: router))
        XCTAssertFalse(perform(.addFiveMinutes, with: router))
        XCTAssertFalse(perform(.undo, with: router))
    }

    @MainActor
    func testWeekBindingUsesTheExistingWorkspaceNavigationRoute() async throws {
        let fixture = try KeysFixture()
        defer { fixture.cleanUp() }
        let router = KeysShortcutRouter(store: fixture.store, model: NotchModel())
        let observation = expectation(description: "Week navigation")
        let token = NotificationCenter.default.addObserver(forName: .perchOpenWorkspace, object: nil, queue: .main) {
            note in
            XCTAssertEqual(note.object as? NotchPage, .week)
            observation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        XCTAssertTrue(perform(.openWeek, with: router))
        await fulfillment(of: [observation], timeout: 1)
    }

    @MainActor
    func testHelpOpensOneWindowAndEscapeClosesItThroughTheEventRouter() async throws {
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let fixture = try KeysFixture()
        defer { fixture.cleanUp(); WindowHost.windows["keys"]?.close() }
        let source = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        source.isReleasedWhenClosed = false
        defer { source.close() }
        source.makeKeyAndOrderFront(nil)
        XCTAssertTrue(NSApp.keyWindow === source)
        let model = NotchModel()
        let router = KeysShortcutRouter(store: fixture.store, model: model)
        XCTAssertTrue(router.handle(event(code: 44, characters: "?", window: source, modifiers: .shift)))
        let window = try XCTUnwrap(WindowHost.windows["keys"])
        XCTAssertTrue(window.isVisible)
        let contentView = try XCTUnwrap(window.contentView)
        XCTAssertEqual(contentView.bounds.width, CGFloat(KeyMap.Layout.width))
        XCTAssertEqual(contentView.bounds.height, CGFloat(KeyMap.Layout.height))
        XCTAssertTrue(perform(.showKeys, with: router))
        XCTAssertTrue(WindowHost.windows["keys"] === window)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(NSApp.keyWindow === window)
        let escape = event(code: 53, characters: "\u{1b}", window: window)
        XCTAssertTrue(router.handle(escape))
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testQuestionMarkInATextEditorIsNotAHelpCommand() async throws {
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let fixture = try KeysFixture()
        defer { fixture.cleanUp() }
        let router = KeysShortcutRouter(store: fixture.store, model: NotchModel())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = NSTextView(frame: window.contentView!.bounds)
        window.contentView = editor
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(editor))
        let question = event(code: 44, characters: "?", window: window, modifiers: .shift)
        XCTAssertFalse(router.handle(question))
        editor.insertText("?", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(editor.string, "?")
    }

    @MainActor
    func testInstalledMonitorLeavesShortcutRecordingInControl() async throws {
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        let savedShortcut = UserDefaults.standard.object(forKey: ShortcutStore.defaultsKey)
        defer {
            NSApp.setActivationPolicy(previousPolicy)
            if let savedShortcut {
                UserDefaults.standard.set(savedShortcut, forKey: ShortcutStore.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: ShortcutStore.defaultsKey)
            }
        }
        let fixture = try KeysFixture()
        defer { fixture.cleanUp() }
        let task = try XCTUnwrap(
            fixture.store.addTasks(["Keep the running task"], on: .day(fixture.store.today))?.first)
        XCTAssertNotNil(fixture.store.send(.startTimer(task.id, minutes: 25)))
        XCTAssertNotNil(fixture.store.addTasks(["Preserve this Undo entry"], on: .day(fixture.store.today)))
        let before = fixture.store.planner
        let router = KeysShortcutRouter(store: fixture.store, model: NotchModel())
        router.start()
        defer { withExtendedLifetime(router) {} }
        let navigation = expectation(description: "Recording must not navigate")
        navigation.isInverted = true
        let token = NotificationCenter.default.addObserver(forName: .perchOpenWorkspace, object: nil, queue: .main) {
            _ in navigation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        for (code, characters, modifiers) in [
            (UInt16(53), "\u{1b}", NSEvent.ModifierFlags()),
            (UInt16(19), "2", NSEvent.ModifierFlags.command),
            (UInt16(35), "p", NSEvent.ModifierFlags.command),
            (UInt16(6), "z", NSEvent.ModifierFlags.command),
        ] {
            ShortcutStore.save(.default, notify: false)
            let window = makeWindow()
            defer { window.close() }
            window.contentView = NSHostingView(
                rootView: ShortcutPreferenceRow().padding()
                    .environment(\.accessibilityEnabled, true))
            try await activate(window)
            let button = try await control(in: window) {
                self.attribute($0, "accessibilityRole") as? String == "AXButton"
                    && (self.attribute($0, "accessibilityLabel") as? String == ShortcutKey.default.display
                        || self.attribute($0, "accessibilityTitle") as? String == ShortcutKey.default.display)
            }
            try press(button)
            try await waitFor("The real shortcut recorder must own input") {
                window.firstResponder is KeysShortcutInputOwner
            }
            XCTAssertTrue(window === NSApp.keyWindow)
            NSApp.sendEvent(event(code: code, characters: characters, window: window, modifiers: modifiers))
            try await waitFor("Recording must finish without closing the window") {
                !(window.firstResponder is KeysShortcutInputOwner)
            }
            XCTAssertTrue(window.isVisible)
            let expected = code == 53 ? ShortcutKey.default : ShortcutKey(keyCode: UInt32(code), modifiers: .command)
            XCTAssertEqual(ShortcutStore.load(), expected)
            XCTAssertEqual(fixture.store.planner, before)
            XCTAssertTrue(fixture.store.canUndo)
            XCTAssertFalse(fixture.store.canRedo)
        }
        await fulfillment(of: [navigation], timeout: 0.05)
        fixture.store.undo()
        XCTAssertEqual(
            fixture.store.planner.tasks.map(\.id), [task.id], "Recording must preserve the original Undo entry")
    }

    @MainActor
    func testInstalledMonitorLeavesTaskDetailsSheetInControl() async throws {
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let fixture = try KeysFixture()
        defer { fixture.cleanUp() }
        let task = try XCTUnwrap(
            fixture.store.addTasks(["Keep sheet edits local"], on: .day(fixture.store.today))?.first)
        XCTAssertNotNil(fixture.store.send(.startTimer(task.id, minutes: 25)))
        XCTAssertNotNil(fixture.store.addTasks(["Preserve this Undo entry"], on: .day(fixture.store.today)))
        let router = KeysShortcutRouter(store: fixture.store, model: NotchModel())
        router.start()
        defer { withExtendedLifetime(router) {} }
        let navigation = expectation(description: "A sheet must not navigate the workspace")
        navigation.isInverted = true
        let token = NotificationCenter.default.addObserver(forName: .perchOpenWorkspace, object: nil, queue: .main) {
            _ in navigation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let presentation = KeysDetailsPresentation()
        let window = makeWindow()
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close()
        }
        window.contentView = NSHostingView(
            rootView: KeysDetailsPresenter(presentation: presentation, store: fixture.store, taskID: task.id))
        try await activate(window)
        presentation.isPresented = true
        try await waitFor("The task-details sheet must be attached") { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        try await activate(sheet)
        XCTAssertTrue(sheet.isSheet)
        XCTAssertTrue(sheet.sheetParent === window)
        XCTAssertNil(sheet.attachedSheet)
        let titleControl = try await control(in: sheet) {
            ($0 as? NSTextField)?.placeholderString == "Task title"
        }
        let field = try XCTUnwrap(titleControl as? NSTextField)
        XCTAssertTrue(sheet.makeFirstResponder(field))
        try await waitFor("The sheet title must have a text editor") { sheet.firstResponder is NSTextView }
        let editor = try XCTUnwrap(sheet.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Discard this draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        let before = fixture.store.planner
        let cancel = try await control(in: sheet) {
            self.attribute($0, "accessibilityIdentifier") as? String == "details-cancel"
        }
        for textFocused in [true, false] {
            if !textFocused {
                let selector = NSSelectorFromString("setAccessibilityFocused:")
                let implementation = try XCTUnwrap(cancel.responds(to: selector) ? cancel.method(for: selector) : nil)
                typealias Focus = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(implementation, to: Focus.self)(cancel, selector, true)
                try await waitFor("The sheet Cancel button must own focus") {
                    let getter = NSSelectorFromString("isAccessibilityFocused")
                    guard cancel.responds(to: getter), let method = cancel.method(for: getter) else { return false }
                    typealias Focused = @convention(c) (AnyObject, Selector) -> Bool
                    return unsafeBitCast(method, to: Focused.self)(cancel, getter)
                }
                XCTAssertFalse(sheet.firstResponder is NSTextView)
            }
            for (code, characters) in [(UInt16(35), "p"), (UInt16(24), "+"), (UInt16(19), "2"), (UInt16(6), "z")] {
                XCTAssertTrue(sheet === NSApp.keyWindow)
                NSApp.sendEvent(event(code: code, characters: characters, window: sheet, modifiers: .command))
                XCTAssertEqual(fixture.store.planner, before)
                XCTAssertTrue(fixture.store.canUndo)
                XCTAssertFalse(fixture.store.canRedo)
                XCTAssertTrue(presentation.isPresented)
            }
        }
        NSApp.sendEvent(event(code: 53, characters: "\u{1b}", window: sheet))
        try await waitFor("Escape must reach the sheet's Cancel action") {
            !presentation.isPresented && window.attachedSheet == nil
        }
        XCTAssertEqual(fixture.store.planner, before)
        await fulfillment(of: [navigation], timeout: 0.05)
        fixture.store.undo()
        XCTAssertEqual(
            fixture.store.planner.tasks.map(\.id), [task.id], "The sheet must preserve the original Undo entry")
    }

    @MainActor
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 780),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor
    private func activate(_ window: NSWindow) async throws {
        try await waitFor("Native key events require an active key window") {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return window === NSApp.keyWindow
        }
    }

    @MainActor
    private func waitFor(_ message: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<30 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail(message)
        throw KeysTestError.unavailableControl
    }

    @MainActor
    private func control(in window: NSWindow, matching predicate: (NSObject) -> Bool) async throws -> NSObject {
        try await waitFor("The native control must be available") { nodes(window).contains(where: predicate) }
        return try XCTUnwrap(nodes(window).first(where: predicate))
    }

    @MainActor
    private func attribute(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
    }

    @MainActor
    private func nodes(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        @MainActor func walk(_ node: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            var children = ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"]
                .flatMap { attribute(node, $0) as? [NSObject] ?? [] }
            if let view = node as? NSView { children += view.subviews }
            if let window = node as? NSWindow, let content = window.contentView { children.append(content) }
            return [node] + children.flatMap(walk)
        }
        return walk(root)
    }

    @MainActor
    private func press(_ node: NSObject) throws {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let implementation = try XCTUnwrap(node.responds(to: selector) ? node.method(for: selector) : nil)
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(implementation, to: Press.self)(node, selector))
    }

    @MainActor
    func testDetachedEventsAreNeverConsumed() async throws {
        let fixture = try KeysFixture()
        defer { fixture.cleanUp() }
        let router = KeysShortcutRouter(store: fixture.store, model: NotchModel())
        let question = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0, context: nil,
                characters: "?", charactersIgnoringModifiers: "/", isARepeat: false, keyCode: 44))
        XCTAssertFalse(router.handle(question))
    }

    #if DEBUG || PERCH_TESTING
        @MainActor
        func testKeysPreviewTargetIsRegistered() async throws {
            XCTAssertNoThrow(try AppDelegate.previewTarget("keys"))
        }
    #endif

    @MainActor
    private func perform(_ action: KeyMap.Action, with router: KeysShortcutRouter) -> Bool {
        let entry = KeyMap.allEntries.first { $0.id == action }!
        return router.bindings.handle(entry.gestures[0].example, context: .application)
    }

    @MainActor
    private func event(code: UInt16, characters: String, window: NSWindow, modifiers: NSEvent.ModifierFlags = [])
        -> NSEvent
    {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
            keyCode: code)!
    }
}

private enum KeysTestError: Error { case unavailableControl }

@MainActor
private final class KeysDetailsPresentation: ObservableObject {
    @Published var isPresented = false
}

@MainActor
private struct KeysDetailsPresenter: View {
    @ObservedObject var presentation: KeysDetailsPresentation
    let store: PlannerStore
    let taskID: UUID

    var body: some View {
        Text("Synthetic task host").frame(width: 640, height: 780)
            .sheet(isPresented: $presentation.isPresented) {
                TaskDetailsSheet(taskID: taskID).environmentObject(store)
                    .environment(\.accessibilityEnabled, true)
            }
    }
}

@MainActor
private struct KeysFixture {
    let directory: URL
    let store: PlannerStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        store = PlannerStore(file: file, now: { PlannerPreviewScenarios.referenceDate }, watching: false)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}
