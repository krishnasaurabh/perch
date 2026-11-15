import AppKit
import PlannerCore
import PerchUI
import XCTest
@testable import PerchApp

final class MenuBarItemTests: XCTestCase {
    @MainActor
    private func allowStatusBarWindows() -> NSApplication.ActivationPolicy {
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        // Allow status windows in the unbundled test host, then restore its original policy.
        XCTAssertTrue(app.setActivationPolicy(.accessory))
        return policy
    }

    @MainActor
    private func waitForVisible(_ item: NSStatusItem) async throws {
        // Let AppKit install the status window without blocking its main run loop.
        for _ in 0..<100 {
            if item.isVisible { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor
    func testExplicitNavigationCallbackWithDefaultDependencies() async throws {
        let policy = allowStatusBarWindows()
        defer { NSApp.setActivationPolicy(policy) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(
            file: PlannerFile(
                url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences()),
            watching: false)
        var navigations: [MenuBarModel.Action] = []
        let item = MenuBarItem(store: store, navigate: { navigations.append($0) })
        defer { item.stop() }
        let today = try XCTUnwrap(item.menu.items.first { $0.identifier?.rawValue == "menubar.openToday" })
        XCTAssertTrue(today.isEnabled)
        item.menu.performActionForItem(at: item.menu.index(of: today))
        XCTAssertEqual(navigations, [.openToday])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.url.path))
    }

    @MainActor
    func testRealStatusItemLifecycleAndTypedPersistedUpdates() async throws {
        let policy = allowStatusBarWindows()
        defer { NSApp.setActivationPolicy(policy) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = MemoryPlannerPreferences()
        let file = PlannerFile(url: root.appendingPathComponent("planner.json"), preferences: preferences)
        let store = PlannerStore(file: file, watching: false)
        let item = MenuBarItem(store: store, shortcut: { .default })
        defer { item.stop() }
        let original = try XCTUnwrap(item.statusItem)
        XCTAssertTrue(try XCTUnwrap(original.button?.image).isTemplate)
        try await waitForVisible(original)
        XCTAssertTrue(original.isVisible)
        try XCTUnwrap(store.apply { try $0.updatePreference(.menuBarDisplay(.hidden)) })
        XCTAssertNil(item.statusItem)
        XCTAssertFalse(original.isVisible)
        try XCTUnwrap(store.apply { try $0.updatePreference(.menuBarDisplay(.icon)) })
        let restored = try XCTUnwrap(item.statusItem)
        XCTAssertFalse(restored === original)
        try await waitForVisible(restored)
        XCTAssertTrue(restored.isVisible)
        try XCTUnwrap(store.apply { try $0.updatePreference(.hideCountsAndTimes(false)) })
        try XCTUnwrap(store.apply { try $0.updatePreference(.menuBarDisplay(.tasksLeft)) })
        XCTAssertEqual(item.presentation.item.text, "0 left")
        XCTAssertFalse(try XCTUnwrap(item.statusItem?.button?.image).isTemplate)
        XCTAssertEqual(item.statusItem?.button?.accessibilityLabel(), item.presentation.item.accessibilityLabel)
        XCTAssertEqual(try file.load().preferences.menuBarDisplay, .tasksLeft)
        let restarted = PlannerStore(file: file, watching: false)
        let second = MenuBarItem(store: restarted, shortcut: { .default })
        defer { second.stop() }
        XCTAssertEqual(second.presentation.item.text, "0 left")
        XCTAssertNotNil(second.statusItem)
        item.stop()
        try XCTUnwrap(store.apply { try $0.updatePreference(.menuBarDisplay(.icon)) })
        XCTAssertNil(item.statusItem, "Stopping removes the item and its saved-update subscription")
    }

    @MainActor
    func testNativeMenuActionsPersistAndRedactVisibleAndAccessibleValues() async throws {
        let policy = allowStatusBarWindows()
        defer { NSApp.setActivationPolicy(policy) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = PlannerStore(
            file: PlannerFile(
                url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences()),
            now: { now }, watching: false)
        try XCTUnwrap(store.apply { try $0.updatePreference(.hideCountsAndTimes(false)) })
        try XCTUnwrap(store.apply { try $0.updatePreference(.menuBarDisplay(.timeLeft)) })
        let task = try XCTUnwrap(store.addTasks(["Synthetic checklist"], on: .day(store.today), literal: true)?.first)
        try XCTUnwrap(store.apply { try $0.startTimer(task: task.id, minutes: 25) })
        let item = MenuBarItem(store: store, shortcut: { .default })
        defer { item.stop() }
        XCTAssertEqual(item.presentation.item.text, "25:00")
        XCTAssertEqual(
            item.menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.identifier?.rawValue),
            [
                "menubar.runningBlock", "menubar.addTask", "menubar.openToday", "menubar.openWeek", "menubar.privacy",
                "menubar.settings", "menubar.quit",
            ])
        let view = try XCTUnwrap(item.runningView)
        view.pauseButton.performClick(nil)
        XCTAssertEqual(try store.file.load().focus?.state, .paused)
        XCTAssertEqual(item.runningView?.pauseButton.title, "Continue")
        item.runningView?.extendButton.performClick(nil)
        XCTAssertEqual(try store.file.load().focus?.limit, 30 * 60)
        item.runningView?.pauseButton.performClick(nil)
        XCTAssertEqual(try store.file.load().focus?.state, .running)
        let privacy = try XCTUnwrap(item.menu.items.first { $0.identifier?.rawValue == "menubar.privacy" })
        item.menu.performActionForItem(at: item.menu.index(of: privacy))
        XCTAssertTrue(try store.file.load().preferences.hideCountsAndTimes)
        XCTAssertEqual(privacy.state, .on)
        XCTAssertNil(item.presentation.item.text)
        let button = try XCTUnwrap(item.statusItem?.button)
        for text in [
            button.accessibilityLabel(), button.toolTip, button.image?.accessibilityDescription,
            item.runningView?.detailLabel.stringValue,
        ] {
            XCTAssertFalse((text ?? "").contains("30:00"))
            XCTAssertFalse((text ?? "").contains("left"))
        }
        try XCTUnwrap(store.apply { try $0.stopTimer() })
        XCTAssertNil(item.runningView)
        XCTAssertFalse(item.menu.items.contains { $0.identifier?.rawValue == "menubar.runningBlock" })
    }

    @MainActor
    func testNavigationAndMenuKeyboardEquivalents() async throws {
        let policy = allowStatusBarWindows()
        defer { NSApp.setActivationPolicy(policy) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(
            file: PlannerFile(
                url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences()),
            watching: false)
        var navigations: [MenuBarModel.Action] = []
        let item = MenuBarItem(store: store, shortcut: { .default }, navigate: { navigations.append($0) })
        defer { item.stop() }
        for action in [MenuBarModel.Action.addTask, .openToday, .openWeek, .settings, .quit] {
            let entry = try XCTUnwrap(item.menu.items.first { $0.identifier?.rawValue == "menubar.\(action.rawValue)" })
            XCTAssertTrue(entry.isEnabled)
            item.menu.performActionForItem(at: item.menu.index(of: entry))
        }
        XCTAssertEqual(navigations, [.addTask, .openToday, .openWeek, .settings, .quit])
        let add = try XCTUnwrap(item.menu.items.first { $0.identifier?.rawValue == "menubar.addTask" })
        XCTAssertEqual(add.keyEquivalent, "n")
        XCTAssertEqual(add.keyEquivalentModifierMask, .option)
        XCTAssertEqual(
            item.menu.items.first { $0.identifier?.rawValue == "menubar.settings" }?.keyEquivalentModifierMask, .command
        )
        try XCTUnwrap(store.apply { try $0.startTimer(task: nil, minutes: 25) })
        let pause = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35))
        XCTAssertTrue(item.menu.performKeyEquivalent(with: pause))
        XCTAssertEqual(try store.file.load().focus?.state, .paused)
        // Ignoring modifiers preserves Shift: the physical Shift-= key produces "+" in both fields.
        let extend = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
                context: nil, characters: "+", charactersIgnoringModifiers: "+", isARepeat: false, keyCode: 24))
        XCTAssertTrue(item.menu.performKeyEquivalent(with: extend))
        XCTAssertEqual(try store.file.load().focus?.limit, 30 * 60)
        let repeatPause = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                characters: "p", charactersIgnoringModifiers: "p", isARepeat: true, keyCode: 35))
        XCTAssertFalse(item.menu.performKeyEquivalent(with: repeatPause))
        XCTAssertEqual(try store.file.load().focus?.state, .paused)
        try XCTUnwrap(store.apply { try $0.stopTimer() })
        XCTAssertFalse(item.menu.performKeyEquivalent(with: pause))
    }

    @MainActor
    func testTaskChangesAndShortcutRollbackRefreshTheExistingItem() async throws {
        let policy = allowStatusBarWindows()
        defer { NSApp.setActivationPolicy(policy) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(
            file: PlannerFile(
                url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences()),
            watching: false)
        try XCTUnwrap(store.apply { try $0.updatePreference(.hideCountsAndTimes(false)) })
        try XCTUnwrap(store.apply { try $0.updatePreference(.menuBarDisplay(.tasksLeft)) })
        var shortcut = ShortcutKey.default
        let item = MenuBarItem(store: store, shortcut: { shortcut })
        defer { item.stop() }
        let original = try XCTUnwrap(item.statusItem)
        let task = try XCTUnwrap(store.addTasks(["Synthetic entry"], on: .day(store.today), literal: true)?.first)
        XCTAssertEqual(item.presentation.item.text, "1 left")
        XCTAssertTrue(item.statusItem === original)
        try XCTUnwrap(store.apply { try $0.complete(task.id) })
        XCTAssertEqual(item.presentation.item.text, "0 left")
        XCTAssertTrue(item.statusItem === original)
        shortcut = .init(keyCode: 40, modifiers: [.control, .option])
        NotificationCenter.default.post(name: ShortcutStore.didChange, object: nil)
        let add = try XCTUnwrap(item.menu.items.first { $0.identifier?.rawValue == "menubar.addTask" })
        XCTAssertEqual(add.keyEquivalent, "k")
        XCTAssertEqual(add.keyEquivalentModifierMask, [.control, .option])
        shortcut = .default
        NotificationCenter.default.post(name: ShortcutStore.didFail, object: nil)
        XCTAssertEqual(add.keyEquivalent, "n")
        XCTAssertEqual(add.keyEquivalentModifierMask, .option)
    }

    @MainActor
    func testHiddenAtStartupAndPrivacyAtStartupAreAppliedWithoutWrites() async throws {
        let policy = allowStatusBarWindows()
        defer { NSApp.setActivationPolicy(policy) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var prefs = Preferences()
        prefs.menuBarDisplay = .hidden
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"),
            preferences: MemoryPlannerPreferences(DevicePreferences(prefs)))
        let store = PlannerStore(file: file, watching: false)
        let item = MenuBarItem(store: store, shortcut: { .default })
        defer { item.stop() }
        XCTAssertNil(item.statusItem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        try XCTUnwrap(store.apply { try $0.updatePreference(.menuBarDisplay(.tasksLeft)) })
        XCTAssertNotNil(item.statusItem)
        XCTAssertNil(item.presentation.item.text)
        XCTAssertEqual(item.statusItem?.button?.accessibilityLabel(), "Perch. Counts and times hidden.")
    }
}
