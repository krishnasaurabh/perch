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
        XCTAssertEqual(window.contentView?.bounds.width, KeyMap.Layout.width)
        XCTAssertEqual(window.contentView?.bounds.height, KeyMap.Layout.height)
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
