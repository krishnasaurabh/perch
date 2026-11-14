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
