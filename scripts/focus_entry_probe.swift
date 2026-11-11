// CI-only entry point. Real views and button actions; direct mutations are fixture setup only.
import AppKit
import ApplicationServices
@testable import PlannerCore
#if canImport(PerchApp)
    @testable import PerchApp
    import PerchUI
    import PerchMCP
#endif
import SwiftUI

@MainActor
func require(_ ok: @autoclosure () -> Bool, _ message: String) {
    guard ok() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}
@MainActor
func settle() async { try? await Task.sleep(nanoseconds: 700_000_000) }
func wakeAX() async {
    await Task.detached {
        let app = AXUIElementCreateApplication(getpid())
        var result: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &result)
        for window in (result as? [AXUIElement]) ?? [] {
            var children: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children)
        }
    }.value
}
@MainActor
func attr(_ node: NSObject, _ name: String) -> Any? {
    let selector = NSSelectorFromString(name)
    return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
}
// Focus is a BOOL-returning Objective-C getter, not an object attribute.
@MainActor
func isFocused(_ node: NSObject) -> Bool {
    let selector = NSSelectorFromString("isAccessibilityFocused")
    guard node.responds(to: selector), let impl = node.method(for: selector) else { return false }
    typealias Focused = @convention(c) (AnyObject, Selector) -> Bool
    return unsafeBitCast(impl, to: Focused.self)(node, selector)
}
@MainActor
final class FocusProbeElement: NSObject {
    let focused: Bool
    init(_ focused: Bool) { self.focused = focused }
    @objc func isAccessibilityFocused() -> Bool { focused }
}
@MainActor
func nodes(_ root: NSObject) -> [NSObject] {
    var seen = Set<ObjectIdentifier>()
    func walk(_ node: NSObject, _ depth: Int) -> [NSObject] {
        guard depth < 60, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
        let children = ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"]
            .flatMap { (attr(node, $0) as? [NSObject]) ?? [] }
        return [node] + children.flatMap { walk($0, depth + 1) }
    }
    return walk(root, 0)
}
@MainActor
func control(_ value: String, attribute: String = "accessibilityLabel", in root: NSView) -> NSObject? {
    nodes(root).first { attr($0, attribute) as? String == value }
}
// Unlabelled Text may publish its string as AXValue rather than AXDescription.
// Require the static-text role so a button with the same title is never a match.
@MainActor
func isStaticText(_ node: NSObject, matching text: String) -> Bool {
    attr(node, "accessibilityRole") as? String == "AXStaticText"
        && (attr(node, "accessibilityLabel") as? String == text
            || attr(node, "accessibilityValue") as? String == text)
}
@MainActor
func staticText(_ text: String, in root: NSView) -> NSObject? {
    let matches = nodes(root).filter { isStaticText($0, matching: text) }
    return matches.count == 1 ? matches[0] : nil
}
@MainActor
final class StaticTextProbeElement: NSObject {
    let role: String
    let label: String?
    let value: String?
    init(role: String = "AXStaticText", label: String? = nil, value: String? = nil) {
        self.role = role; self.label = label; self.value = value
    }
    @objc func accessibilityRole() -> String { role }
    @objc func accessibilityLabel() -> String? { label }
    @objc func accessibilityValue() -> String? { value }
}
@MainActor
func recordAccessibility(_ root: NSView, _ name: String, into output: URL) {
    let tree = nodes(root).map { node in
        [
            "class": String(describing: type(of: node)),
            "role": attr(node, "accessibilityRole") as? String ?? "",
            "label": attr(node, "accessibilityLabel") as? String ?? "",
            "value": attr(node, "accessibilityValue") as? String ?? "",
            "identifier": attr(node, "accessibilityIdentifier") as? String ?? "",
            "frame": NSStringFromRect(frame(node)),
            "hint": attr(node, "accessibilityHelp") as? String ?? "",
            "focused": isFocused(node) ? "true" : "false",
            "actions": customActions(node).map(\.name).joined(separator: ", "),
        ]
    }
    try! JSONSerialization.data(withJSONObject: tree, options: [.prettyPrinted, .sortedKeys]).write(
        to: output.appendingPathComponent(name + "-ax.json"))
}
@MainActor
func press(_ node: NSObject, _ label: String) {
    let selector = NSSelectorFromString("accessibilityPerformPress")
    guard node.responds(to: selector), let impl = node.method(for: selector) else {
        require(false, "real button can press: \(label)"); return
    }
    typealias Press = @convention(c) (AnyObject, Selector) -> Bool
    require(unsafeBitCast(impl, to: Press.self)(node, selector), "real AX press: \(label)")
}
@MainActor
func press(_ label: String, in root: NSView) {
    guard let node = control(label, in: root) else { require(false, "button exists: \(label)"); return }
    press(node, label)
}
@MainActor
func frame(_ node: NSObject) -> CGRect {
    guard node.responds(to: NSSelectorFromString("accessibilityFrame")),
        let value = node.value(forKey: "accessibilityFrame") as? NSValue
    else { return .zero }
    return value.rectValue
}
@MainActor
func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
// Observe only menus opened by real event dispatch. Menu tracking runs a nested
// event loop, so a selector timer in that mode must close it before sendEvent returns.
@MainActor
final class ContextMenuObservation: NSObject {
    private var menus: [NSMenu] = []
    private var timer: Timer?
    private let deadline = ProcessInfo.processInfo.systemUptime + 5
    private(set) var matchedMenu: NSMenu?
    private(set) var timedOut = false
    private(set) var observedTitles: [[String]] = []

    func start() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuBeganTracking(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        let timer = Timer(
            timeInterval: 0.05, target: self, selector: #selector(inspectMenus), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func menuBeganTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        menus.append(menu)
    }

    @objc private func inspectMenus() {
        guard matchedMenu == nil else { return }
        for menu in menus {
            let titles = menu.items.map(\.title)
            if !observedTitles.contains(titles) { observedTitles.append(titles) }
            if let index = menu.items.firstIndex(where: { $0.title == "Start focusing" }) {
                matchedMenu = menu
                require(menu.items[index].isEnabled, "existing task menu item enabled")
                // Invoke while tracking still retains SwiftUI's action target; cancellation
                // may tear it down. This is the actual menu action, not a model fallback.
                menu.performActionForItem(at: index)
                menu.cancelTracking()
                return
            }
        }
        if ProcessInfo.processInfo.systemUptime >= deadline {
            timedOut = true
            for menu in menus { menu.cancelTracking() }
        }
    }
}
@MainActor
func snapshot(_ root: NSView, _ name: String, into output: URL) {
    root.layoutSubtreeIfNeeded()
    guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
        require(false, "bitmap \(name)"); return
    }
    root.cacheDisplay(in: root.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { require(false, "PNG \(name)"); return }
    try! data.write(to: output.appendingPathComponent(name + ".png"))
}
@MainActor
func sendKey(
    _ type: NSEvent.EventType, _ character: String, code: UInt16, in window: NSWindow, isARepeat: Bool = false,
    modifiers: NSEvent.ModifierFlags = []
) {
    let event = NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: character,
        charactersIgnoringModifiers: character, isARepeat: isARepeat, keyCode: code)!
    NSApp.sendEvent(event)
}
@MainActor
func key(_ character: String, code: UInt16, in window: NSWindow) {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        sendKey(type, character, code: code, in: window)
    }
}

// Edits, including Undo, legitimately advance updatedAt. Every other task field
// and the displayed ordering must still match, and timestamps must not regress.
func sameTaskContent(_ actual: [PlanTask], _ expected: [PlanTask]) -> Bool {
    guard actual.count == expected.count else { return false }
    return zip(actual, expected).allSatisfy { current, prior in
        guard current.updatedAt >= prior.updatedAt else { return false }
        var content = current
        content.updatedAt = prior.updatedAt
        return content == prior
    }
}

@MainActor
func customActions(_ node: NSObject) -> [NSAccessibilityCustomAction] {
    (attr(node, "accessibilityCustomActions") as? [NSAccessibilityCustomAction]) ?? []
}

@MainActor
func performCustomAction(_ name: String, taskID: UUID, in root: NSView) {
    guard let row = control("task-row-\(taskID)", attribute: "accessibilityIdentifier", in: root) else {
        require(false, "custom action row exists: \(taskID)"); return
    }
    let matches = customActions(row).filter { $0.name == name }
    require(matches.count == 1, "exactly one native row action: \(name)")
    let action = matches[0]
    if let handler = action.handler {
        require(handler(), "native custom action handled: \(name)")
    } else if let target = action.target, let selector = action.selector {
        require(NSApp.sendAction(selector, to: target, from: action), "native custom action dispatched: \(name)")
    } else {
        require(false, "native custom action has a handler or target: \(name)")
    }
}

@MainActor
func focusByTab(_ identifier: String, in window: NSWindow, root: NSView, output: URL) async -> Bool {
    window.makeFirstResponder(nil)
    var trace: [[String: Any]] = []
    for step in 0..<60 {
        key("\t", code: 48, in: window)
        try? await Task.sleep(nanoseconds: 50_000_000)
        trace.append([
            "step": step, "target": identifier, "keyWindow": window.isKeyWindow,
            "firstResponder": String(describing: window.firstResponder),
            "focusedIdentifiers": nodes(root).filter(isFocused).map {
                attr($0, "accessibilityIdentifier") as? String
                    ?? attr($0, "accessibilityLabel") as? String ?? "unnamed"
            },
        ])
        try! JSONSerialization.data(withJSONObject: trace, options: [.prettyPrinted]).write(
            to: output.appendingPathComponent("tab-trace-\(identifier).json"))
        if let node = control(identifier, attribute: "accessibilityIdentifier", in: root), isFocused(node) {
            return true
        }
    }
    snapshot(root, "tab-failed-\(identifier)", into: output)
    return false
}

@MainActor
func verifyLastRowKeyboardUndo(store: PlannerStore, model: NotchModel, services: Services, output: URL) async {
    for completed in [false, true] {
        store.seedFixture { engine in
            engine.planner.tasks = []; engine.planner.focus = nil
        }
        let only = store.apply { try $0.addTasks(["Inspect the porch light"], on: .day(store.today)) }![0]
        if completed { _ = store.send(.complete(only.id)) }
        let beforeDeletion = store.planner.tasks
        let panel = NotchPanel(frame: CGRect(x: 50, y: 100, width: 420, height: 400))
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false
        var undoCount = 0
        panel.onUndo = { redo in
            undoCount += 1
            if redo { store.redo() } else { store.undo() }
        }
        let root = NSHostingView(
            rootView: TasksCard().environmentObject(store).environmentObject(model).environmentObject(services)
                .environment(\.accessibilityEnabled, true))
        panel.contentView = root
        panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        await settle(); await wakeAX(); await settle()
        require(panel.isKeyWindow, "last-row keyboard test owns the key NotchPanel")
        if completed { press("Completed 1", in: root); await settle() }
        let reachedCompletion = await focusByTab("task-complete-\(only.id)", in: panel, root: root, output: output)
        require(reachedCompletion, "Tab reaches the last row completion control")
        let actionOrder = completed ? ["details", "delete"] : ["focus", "details", "delete"]
        for action in actionOrder {
            key("\t", code: 48, in: panel); await settle()
            recordAccessibility(root, "last-row-\(completed)-tab-\(action)", into: output)
            let node = control("task-\(action)-\(only.id)", attribute: "accessibilityIdentifier", in: root)
            require(node.map(isFocused) == true, "Tab reaches row \(action) in visible order")
            if action == "details" {
                key(" ", code: 49, in: panel); await settle()
                require(model.detailsTaskID == only.id, "row Details keyboard action targets the exact task")
                require(store.planner.tasks == beforeDeletion, "row Details keyboard action does not mutate tasks")
                model.detailsTaskID = nil
            }
        }
        let reachedDelete =
            control("task-delete-\(only.id)", attribute: "accessibilityIdentifier", in: root)
            .map(isFocused) == true
        recordAccessibility(root, "last-row-\(completed)-before-delete", into: output)
        require(reachedDelete, "Tab reaches the last row Delete control")
        key(" ", code: 49, in: panel); await settle()
        require(store.planner.tasks.isEmpty, "keyboard Delete removes the last displayed task")
        require(try! store.file.load().tasks.isEmpty, "last-row keyboard deletion persists")
        recordAccessibility(root, "last-row-\(completed)-after-delete", into: output)
        let undo = control("today-undo", attribute: "accessibilityIdentifier", in: root)
        require(undo.map(isFocused) == true, "last-row removal focuses Undo")
        require(!(panel.firstResponder is NSTextView), "task Undo does not have a text first responder")
        sendKey(.keyDown, "z", code: 6, in: panel, modifiers: [.command])
        sendKey(.keyUp, "z", code: 6, in: panel, modifiers: [.command])
        await settle()
        require(undoCount == 1, "NotchPanel routes Command-Z to planner Undo once")
        require(sameTaskContent(store.planner.tasks, beforeDeletion), "keyboard Undo restores exact last-row state")
        require(
            sameTaskContent(try! store.file.load().tasks, beforeDeletion), "last-row keyboard Undo persists exact task")
        // Removing the last completed row selects To do; Undo restores content, not the selected filter.
        if completed { press("Completed 1", in: root); await settle() }
        recordAccessibility(root, "last-row-\(completed)-before-second-delete", into: output)
        require(
            control("task-delete-\(only.id)", attribute: "accessibilityIdentifier", in: root) != nil,
            "restored task Delete control is visible before keyboard traversal")
        let deleteAgain = await focusByTab("task-delete-\(only.id)", in: panel, root: root, output: output)
        require(deleteAgain, "Tab reaches Delete again after Command-Z")
        key(" ", code: 49, in: panel); await settle()
        require(store.planner.tasks.isEmpty, "second keyboard deletion removes the same task")
        let undoAgain = control("today-undo", attribute: "accessibilityIdentifier", in: root)
        require(undoAgain.map(isFocused) == true, "second last-row removal focuses Undo")
        sendKey(.keyDown, " ", code: 49, in: panel); await settle()
        require(sameTaskContent(store.planner.tasks, beforeDeletion), "Space activates visible Undo")
        require(sameTaskContent(try! store.file.load().tasks, beforeDeletion), "Space Undo persists exact task")
        let afterUndo = store.planner.tasks
        sendKey(.keyDown, " ", code: 49, in: panel, isARepeat: true)
        sendKey(.keyUp, " ", code: 49, in: panel); await settle()
        require(store.planner.tasks == afterUndo, "held Space does not consume another Undo")

        // Text editing still owns Command-Z when the user intentionally returns to capture.
        panel.makeFirstResponder(nil)
        for _ in 0..<60 {
            key("\t", code: 48, in: panel)
            try? await Task.sleep(nanoseconds: 50_000_000)
            if panel.firstResponder is NSTextView { break }
        }
        guard let editor = panel.firstResponder as? NSTextView else {
            require(false, "Tab reaches the real capture text editor"); return
        }
        let oldText = editor.string
        editor.insertText("temporary draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        require(editor.string != oldText, "capture receives draft text")
        editor.breakUndoCoalescing()
        sendKey(.keyDown, "z", code: 6, in: panel, modifiers: [.command])
        sendKey(.keyUp, "z", code: 6, in: panel, modifiers: [.command])
        await settle()
        require(undoCount == 1 && store.planner.tasks == afterUndo, "capture Command-Z preserves planner history")
        require(editor.string == oldText, "capture Command-Z undoes only draft text")
        if !completed {
            let reachedFocus = await focusByTab("task-focus-\(only.id)", in: panel, root: root, output: output)
            require(reachedFocus, "Tab reaches the row Focus control")
            sendKey(.keyDown, " ", code: 49, in: panel); await settle()
            let session = store.planner.focus
            require(
                session?.state == .running && session?.taskID == only.id
                    && session?.limit == TimeInterval(store.planner.preferences.defaultFocusMinutes * 60),
                "Space starts one focus session for the exact task")
            require(try! store.file.load().focus == session, "row keyboard focus session persists")
            sendKey(.keyDown, " ", code: 49, in: panel, isARepeat: true)
            sendKey(.keyUp, " ", code: 49, in: panel); await settle()
            require(
                store.planner.focus?.startedAt == session?.startedAt, "held Space does not start another focus session")
            require(store.planner.tasks == afterUndo, "keyboard focus leaves task content unchanged")
        }
        snapshot(root, "last-row-\(completed)-restored", into: output)
        panel.orderOut(nil)
    }
}

@MainActor
func verifyRowCustomActions(store: PlannerStore, model: NotchModel, services: Services, output: URL) async {
    store.seedFixture { engine in
        engine.planner.tasks = []; engine.planner.focus = nil
    }
    let tasks = store.apply {
        try $0.addTasks(["Inspect the greenhouse lamps", "Label the spare bulbs"], on: .day(store.today))
    }!
    let target = tasks[0], sentinel = tasks[1]
    store.updateTask(target.id) {
        $0.priority = .medium; $0.minutes = 12
    }
    let original = store.planner.tasks
    let window = NSWindow(
        contentRect: CGRect(x: 50, y: 100, width: 420, height: 400), styleMask: [.titled], backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    let root = NSHostingView(
        rootView: TasksCard().environmentObject(store).environmentObject(model).environmentObject(services)
            .environment(\.accessibilityEnabled, true))
    window.contentView = root; window.makeKeyAndOrderFront(nil)
    await settle(); await wakeAX(); await settle()
    recordAccessibility(root, "custom-actions-active", into: output)
    guard let row = control("task-row-\(target.id)", attribute: "accessibilityIdentifier", in: root) else {
        require(false, "row exposes its own accessibility element"); return
    }
    require(attr(row, "accessibilityLabel") as? String == target.title, "row label is the task title")
    require(
        attr(row, "accessibilityValue") as? String == "Not completed, Medium priority",
        "row value describes state and priority")
    require((attr(row, "accessibilityHelp") as? String ?? "").contains("undone"), "row hint explains deletion recovery")
    require(
        Set(customActions(row).map(\.name)) == ["Complete", "Details", "Delete", "Focus"],
        "active row names all custom actions")
    performCustomAction("Details", taskID: target.id, in: root)
    require(
        model.detailsTaskID == target.id && store.planner.tasks == original,
        "row custom Details selects only the target")
    model.detailsTaskID = nil
    let completionStart = Date()
    performCustomAction("Complete", taskID: target.id, in: root); await settle()
    let completed = try! store.file.load().tasks
    let completedTarget = completed.first { $0.id == target.id }!
    require(
        completedTarget.completedAt.map { $0 >= completionStart && $0 <= Date() } == true,
        "row custom completion records its actual completion time")
    var expectedCompleted = original
    let targetIndex = expectedCompleted.firstIndex { $0.id == target.id }!
    expectedCompleted[targetIndex].done = true
    expectedCompleted[targetIndex].completedAt = completedTarget.completedAt
    require(
        sameTaskContent(completed, expectedCompleted) && completed.first { $0.id == sentinel.id } == sentinel,
        "row custom completion persists only the target")
    press("Completed 1", in: root); await settle()
    guard let completedRow = control("task-row-\(target.id)", attribute: "accessibilityIdentifier", in: root) else {
        require(false, "completed row remains accessible"); return
    }
    require(
        Set(customActions(completedRow).map(\.name)) == ["Reopen", "Details", "Delete"],
        "completed row offers Reopen but no Focus")
    require(
        attr(completedRow, "accessibilityValue") as? String == "Completed, Medium priority",
        "completed row announces its state")
    performCustomAction("Reopen", taskID: target.id, in: root); await settle()
    require(sameTaskContent(try! store.file.load().tasks, original), "row custom reopening persists only the target")
    performCustomAction("Focus", taskID: target.id, in: root); await settle()
    let running = try! store.file.load()
    require(
        running.focus?.taskID == target.id && running.focus?.state == .running && running.focus?.limit == 720,
        "row custom Focus persists exact task and duration")
    guard let runningRow = control("task-row-\(target.id)", attribute: "accessibilityIdentifier", in: root) else {
        require(false, "running row remains accessible"); return
    }
    require(!customActions(runningRow).contains { $0.name == "Focus" }, "running row omits the Focus custom action")
    performCustomAction("Delete", taskID: target.id, in: root); await settle()
    require(try! store.file.load().tasks == [sentinel], "row custom deletion persists only the target")
    press("Undo", in: root); await settle()
    let restored = try! store.file.load()
    require(
        restored.tasks.contains { $0.id == target.id && $0.title == target.title && $0.minutes == 12 }
            && restored.tasks.first { $0.id == sentinel.id } == sentinel,
        "Undo restores custom deletion without changing its neighbor")
    require(restored.focus?.state != .running, "Undo custom deletion never restarts focus")
    recordAccessibility(root, "custom-actions-restored", into: output)
    window.orderOut(nil)
}

MainActor.assumeIsolated {
    require(
        UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") == 3,
        "probe process enables keyboard navigation without changing system preferences")
    require(isFocused(FocusProbeElement(true)), "native focus getter recognizes true")
    require(!isFocused(FocusProbeElement(false)), "native focus getter recognizes false")
    require(!isFocused(NSObject()), "missing native focus getter is not treated as focused")
    let sampleTitle = "Check the seed trays\nRecord watering"
    require(
        isStaticText(StaticTextProbeElement(value: sampleTitle), matching: sampleTitle),
        "static-text selector accepts a value-only title")
    require(
        isStaticText(StaticTextProbeElement(label: sampleTitle), matching: sampleTitle),
        "static-text selector accepts a labelled title")
    require(
        !isStaticText(StaticTextProbeElement(role: "AXButton", label: sampleTitle), matching: sampleTitle),
        "static-text selector rejects an action with matching text")
    require(
        !isStaticText(StaticTextProbeElement(value: "Another title"), matching: sampleTitle)
            && !isStaticText(StaticTextProbeElement(), matching: sampleTitle),
        "static-text selector rejects different and missing text")
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOCUS_ENTRY_OUTPUT"]!)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        Task { @MainActor in
            guard let store = delegate.store else { require(false, "planner initialized"); return }
            setbuf(stdout, nil)
            var metrics: [[String: Any]] = []
            var keyboardVerified = false
            // Exercise the production controller first, not only component fixtures.
            NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.home)
            await settle(); await wakeAX(); await settle()
            guard let live = NSApp.keyWindow?.contentView else { require(false, "live Today exists"); return }
            require(control("Start focus", in: live) != nil, "production Today exposes Start focus")
            snapshot(live, "live-empty-today", into: output)
            press("Start focus", in: live)
            await settle()
            require(
                store.planner.focus?.state == .running && store.planner.focus?.taskID == nil,
                "production button starts task-less focus")
            require(
                store.planner.focus?.limit == Double(store.prefs.defaultFocusMinutes * 60),
                "production default duration")
            require(
                control("Pause", in: live) != nil && control("End focus session", in: live) != nil,
                "production timer controls visible")
            require(control("Start focus", in: live) == nil, "production entry hidden during focus")
            snapshot(live, "live-running-today", into: output)
            press("End focus session", in: live)
            await settle()
            require(
                store.planner.focus == nil && control("Start focus", in: live) != nil, "production stop restores entry")
            delegate.model.close()
            await settle()

            // Widths are test-only proposals to the real WorkspaceView; no product sizing is changed.
            for (name, width) in [("normal", CGFloat(820)), ("compact", CGFloat(620))] {
                store.seedFixture { e in
                    e.planner.tasks = []; e.planner.focus = nil
                    e.planner.preferences.defaultFocusMinutes = name == "normal" ? 25 : 40
                    e.planner.preferences.hiddenWorkspaceCards = ["notepad"]
                }
                let window = NSWindow(
                    contentRect: CGRect(x: 30, y: 100, width: width, height: 351),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let root = NSHostingView(
                    rootView: WorkspaceView(notchHeight: 0)
                        .environmentObject(store).environmentObject(delegate.model).environmentObject(delegate.services)
                        .environment(\.colorScheme, .dark).background(Color.black))
                window.contentView = root
                window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                await settle(); await wakeAX(); await settle()
                require(nodes(root).count > 10, "\(name): live AX tree populated before absence assertions")
                let entry = control("Start focus", in: root)!
                require(
                    attr(entry, "accessibilityRole") as? String == "AXButton", "\(name): entry has button role and name"
                )
                require(
                    attr(entry, "accessibilityIdentifier") as? String == "today-start-focus",
                    "\(name): stable entry identifier")
                let capture = control("Add a task", in: root)!
                let initialCapture = frame(capture)
                require(
                    initialCapture.width > 100 && initialCapture.height > 10, "\(name): capture has a visible viewport")
                require(!frame(entry).intersects(initialCapture), "\(name): entry does not overlap capture")
                snapshot(root, "\(name)-empty", into: output)
                let added = store.apply {
                    try $0.addTasks(
                        ["Inspect the release checklist", "Inspect the release checklist", "Label the storage bins"],
                        on: .day(store.today))
                }!
                let completion = store.send(.complete(added[1].id))
                require(completion?.tasks.first?.done == true, "\(name): completion uses the validated gateway")
                await settle()
                require(control("Completed 1", in: root) != nil, "\(name): completed tab retained beside entry")
                require(frame(capture) == initialCapture, "\(name): population leaves capture pinned")
                snapshot(root, "\(name)-populated", into: output)
                let taskIDs = store.planner.tasks.map(\.id)
                let taskMinutes = store.planner.tasks.map(\.minutes)
                let start = control("Start focus", in: root)!
                press(start, "Start focus")
                let startedAt = store.planner.focus?.startedAt
                // A rapid second press of the stale node must not replace the one running session.
                press(start, "Start focus repeated")
                require(store.planner.focus?.startedAt == startedAt, "\(name): repeated press keeps one session")
                await settle()
                require(
                    store.planner.focus?.state == .running && store.planner.focus?.taskID == nil,
                    "\(name): task-less running state")
                require(
                    store.planner.focus?.limit == Double(store.prefs.defaultFocusMinutes * 60),
                    "\(name): configured default duration")
                require(control("Start focus", in: root) == nil, "\(name): entry absent while running")
                require(
                    control("Pause", in: root) != nil && control("End focus session", in: root) != nil,
                    "\(name): Pause and Stop visible")
                require(
                    nodes(root).contains {
                        (attr($0, "accessibilityValue") as? String ?? attr($0, "accessibilityLabel") as? String ?? "")
                            .contains(":")
                    }, "\(name): timer text is exposed")
                snapshot(root, "\(name)-running", into: output)
                press("Pause", in: root); await settle()
                require(
                    store.planner.focus?.state == .paused && store.planner.focus?.startedAt == startedAt,
                    "\(name): Pause keeps session")
                require(
                    control("Continue", in: root) != nil && control("Start focus", in: root) == nil,
                    "\(name): Continue replaces Pause, entry stays hidden")
                snapshot(root, "\(name)-paused", into: output)
                press("Continue", in: root); await settle()
                require(
                    store.planner.focus?.state == .running && store.planner.focus?.startedAt == startedAt,
                    "\(name): Continue resumes same session")
                press("End focus session", in: root); await settle()
                require(
                    store.planner.focus == nil && control("Start focus", in: root) != nil,
                    "\(name): Stop restores entry")
                require(
                    store.planner.tasks.map(\.id) == taskIDs && store.planner.tasks.map(\.minutes) == taskMinutes,
                    "\(name): task-less lifecycle preserves task identity and estimates")
                require(frame(capture) == initialCapture, "\(name): stop restores pinned capture geometry")
                snapshot(root, "\(name)-stopped", into: output)
                // Keyboard navigation uses real AppKit key dispatch. No AX press or model fallback.
                window.makeFirstResponder(nil)
                for _ in 0..<35 {
                    key("\t", code: 48, in: window)
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    if let focus = control("Start focus", in: root),
                        isFocused(focus)
                    {
                        key(" ", code: 49, in: window); await settle()
                        keyboardVerified = store.planner.focus?.state == .running
                        break
                    }
                }
                if store.planner.focus != nil { press("End focus session", in: root); await settle() }
                window.makeFirstResponder(nil)
                var rowKeyboardReached = false
                var keyboardTrace: [[String: Any]] = []
                @MainActor func recordKeyboardState(_ phase: String) {
                    keyboardTrace.append([
                        "phase": phase, "keyWindow": window.isKeyWindow,
                        "firstResponder": String(describing: window.firstResponder),
                        "focusedIdentifiers": nodes(root).filter(isFocused).map {
                            attr($0, "accessibilityIdentifier") as? String
                                ?? attr($0, "accessibilityLabel") as? String ?? "unnamed"
                        },
                        "completedIDs": store.planner.tasks.filter(\.done).map { $0.id.uuidString },
                        "storeError": String(describing: store.lastError),
                    ])
                    let data = try! JSONSerialization.data(withJSONObject: keyboardTrace, options: [.prettyPrinted])
                    try! data.write(to: output.appendingPathComponent("keyboard-trace-\(name).json"))
                }
                for step in 0..<60 {
                    key("\t", code: 48, in: window)
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    recordKeyboardState("tab-\(step)")
                    guard
                        let first = control(
                            "task-complete-\(added[0].id)", attribute: "accessibilityIdentifier", in: root),
                        isFocused(first)
                    else { continue }
                    rowKeyboardReached = true
                    key("\u{F701}", code: 125, in: window); await settle()
                    guard
                        let next = control(
                            "task-complete-\(added[2].id)", attribute: "accessibilityIdentifier", in: root)
                    else {
                        require(false, "\(name): next row is accessible"); return
                    }
                    require(
                        isFocused(next),
                        "\(name): Down focuses the next displayed task")
                    key("\u{F700}", code: 126, in: window); await settle()
                    let previous = control(
                        "task-complete-\(added[0].id)", attribute: "accessibilityIdentifier", in: root)
                    require(
                        previous.map(isFocused) == true,
                        "\(name): Up returns to the previous task")
                    snapshot(root, "\(name)-row-keyboard-focused", into: output)
                    let completedBeforeSpace = Set(store.planner.tasks.filter(\.done).map(\.id))
                    recordKeyboardState("before-space")
                    sendKey(.keyDown, " ", code: 49, in: window); await settle()
                    recordKeyboardState("after-space")
                    let expectedCompleted = completedBeforeSpace.union([added[0].id])
                    require(
                        Set(store.planner.tasks.filter(\.done).map(\.id)) == expectedCompleted,
                        "\(name): Space completes exactly the focused task")
                    let persistedAfterSpace = try! store.file.load()
                    require(
                        Set(persistedAfterSpace.tasks.filter(\.done).map(\.id)) == expectedCompleted,
                        "\(name): keyboard completion persists the exact task")
                    let nextAfterCompletion = control(
                        "task-complete-\(added[2].id)", attribute: "accessibilityIdentifier", in: root)
                    require(
                        nextAfterCompletion.map(isFocused) == true, "\(name): completion keeps focus on the next task")
                    // Holding Space across focus recovery must not also complete the neighboring row.
                    sendKey(.keyDown, " ", code: 49, in: window, isARepeat: true); await settle()
                    require(
                        Set(store.planner.tasks.filter(\.done).map(\.id)) == expectedCompleted,
                        "\(name): keyDown - no repeated completion")
                    sendKey(.keyUp, " ", code: 49, in: window); await settle()
                    require(
                        Set(store.planner.tasks.filter(\.done).map(\.id)) == expectedCompleted,
                        "\(name): keyUp does not activate the next row")
                    press("Undo", in: root); await settle()
                    require(
                        Set(store.planner.tasks.filter(\.done).map(\.id)) == completedBeforeSpace,
                        "\(name): visible Undo restores keyboard completion")
                    break
                }
                let traceData = try! JSONSerialization.data(withJSONObject: keyboardTrace, options: [.prettyPrinted])
                try! traceData.write(to: output.appendingPathComponent("keyboard-trace-\(name).json"))
                if !rowKeyboardReached { print("Keyboard trace: " + String(decoding: traceData, as: UTF8.self)) }
                require(rowKeyboardReached, "\(name): Tab reaches a real task completion button")
                // The completed list uses the same focused action, not a separate global shortcut.
                press("Completed 1", in: root); await settle()
                window.makeFirstResponder(nil)
                var completedRowReached = false
                for step in 0..<60 {
                    key("\t", code: 48, in: window)
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    recordKeyboardState("completed-tab-\(step)")
                    guard
                        let completed = control(
                            "task-complete-\(added[1].id)", attribute: "accessibilityIdentifier", in: root),
                        isFocused(completed)
                    else { continue }
                    completedRowReached = true
                    key(" ", code: 49, in: window); await settle()
                    recordKeyboardState("after-reopen")
                    require(
                        store.planner.tasks.allSatisfy { !$0.done },
                        "\(name): Space reopens exactly the focused completed task")
                    require(
                        try! store.file.load().tasks.allSatisfy { !$0.done },
                        "\(name): keyboard reopening persists")
                    press("Undo", in: root); await settle()
                    require(
                        Set(store.planner.tasks.filter(\.done).map(\.id)) == [added[1].id],
                        "\(name): Undo restores keyboard reopening")
                    break
                }
                require(completedRowReached, "\(name): Tab reaches the completed task action")
                // Dense rows scroll independently of the still-visible entry and capture.
                store.apply { try $0.addTasks((1...24).map { "Inspect inventory group \($0)" }, on: .day(store.today)) }
                await settle()
                let scrolling = views(root).compactMap { $0 as? NSScrollView }.first {
                    $0.documentView?.frame.height ?? 0 > $0.contentSize.height + 30 && $0.frame.height > 70
                }
                require(scrolling != nil, "\(name): dense tasks remain scrollable")
                let pinned = frame(control("Add a task", in: root)!)
                scrolling?.documentView?.scroll(NSPoint(x: 0, y: 1000)); await settle()
                require(frame(control("Add a task", in: root)!) == pinned, "\(name): scroll leaves capture pinned")
                require(control("Start focus", in: root) != nil, "\(name): scroll leaves entry visible")
                snapshot(root, "\(name)-dense-scrolled", into: output)
                metrics.append([
                    "width": width, "name": name, "capture": NSStringFromRect(initialCapture),
                    "axNodes": nodes(root).count, "defaultMinutes": store.prefs.defaultFocusMinutes,
                ])
                window.orderOut(nil)
            }
            print("Keyboard activation before task route: \(keyboardVerified)")
            await verifyLastRowKeyboardUndo(
                store: store, model: delegate.model, services: delegate.services, output: output)
            await verifyRowCustomActions(
                store: store, model: delegate.model, services: delegate.services, output: output)
            // Dispatch a right-click to the rendered title and observe the menu AppKit actually opens.
            store.seedFixture { e in
                e.planner.tasks = []; e.planner.focus = nil
            }
            let linked = store.apply { try $0.addTasks(["Verify a single linked task"], on: .day(store.today)) }![0]
            store.updateTask(linked.id) { $0.minutes = 12 }
            let rowWindow = NSWindow(
                contentRect: CGRect(x: 50, y: 100, width: 420, height: 140), styleMask: [.titled], backing: .buffered,
                defer: false)
            rowWindow.isReleasedWhenClosed = false
            let rowRoot = NSHostingView(
                rootView: TaskRow(task: store.planner.tasks[0]).environmentObject(store).environmentObject(
                    delegate.model
                ).environment(\.accessibilityEnabled, true))
            rowWindow.contentView = rowRoot; rowWindow.makeKeyAndOrderFront(nil)
            await settle(); await wakeAX(); await settle()
            snapshot(rowRoot, "task-before-context-click", into: output)
            recordAccessibility(rowRoot, "task-before-context-click", into: output)
            guard let title = staticText(linked.title, in: rowRoot) else {
                require(false, "context-click target is the rendered task title"); return
            }
            let titleFrame = frame(title)
            require(titleFrame.width > 0 && titleFrame.height > 0, "context-click title has a visible frame")
            let location = rowWindow.convertPoint(fromScreen: NSPoint(x: titleFrame.midX, y: titleFrame.midY))
            let rootLocation = rowRoot.convert(location, from: nil)
            require(rowRoot.hitTest(rootLocation) != nil, "context-click lands inside the hosted task row")
            let observation = ContextMenuObservation()
            observation.start()
            let contextEvent = NSEvent.mouseEvent(
                with: .rightMouseDown, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rowWindow.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            rowWindow.sendEvent(contextEvent)
            // SwiftUI may begin tracking during dispatch or on the next run-loop pass.
            while observation.matchedMenu == nil && !observation.timedOut {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            observation.stop()
            let contextUp = NSEvent.mouseEvent(
                with: .rightMouseUp, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rowWindow.windowNumber,
                context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
            rowWindow.sendEvent(contextUp)
            let contextTrace: [String: Any] = [
                "mechanism": "window-right-click-tracked-NSMenu-item-action",
                "titleFrame": NSStringFromRect(titleFrame), "windowPoint": NSStringFromPoint(location),
                "keyWindow": rowWindow.isKeyWindow, "menus": observation.observedTitles,
                "timedOut": observation.timedOut,
            ]
            try! JSONSerialization.data(withJSONObject: contextTrace, options: [.prettyPrinted, .sortedKeys]).write(
                to: output.appendingPathComponent("context-menu-trace.json"))
            let taskMenu = observation.matchedMenu
            require(taskMenu != nil, "existing task context menu exposes Start focusing")
            await settle()
            require(
                store.planner.focus?.state == .running
                    && store.planner.focus?.taskID == linked.id && store.planner.focus?.limit == 720,
                "task context-menu action starts the exact task with a 12-minute limit")
            require(
                store.planner.tasks.count == 1 && store.planner.tasks[0].id == linked.id
                    && store.planner.tasks[0].minutes == 12,
                "task action does not change task identity or estimate")
            // Preserve the on-disk running session before the later deletion intentionally stops it.
            try! Data(contentsOf: store.file.url).write(to: output.appendingPathComponent("linked-focus.json"))
            // Real visible controls must work without hover, a context menu, or a swipe.
            for label in ["Complete \(linked.title)", "Details \(linked.title)", "Delete \(linked.title)"] {
                guard let node = control(label, in: rowRoot) else {
                    require(false, "visible row action exists: \(label)"); return
                }
                let bounds = frame(node)
                require(bounds.width >= 28 && bounds.height >= 28, "row action has a 28pt target: \(label)")
            }
            press("Details \(linked.title)", in: rowRoot)
            require(delegate.model.detailsTaskID == linked.id, "visible Details selects exact task")
            delegate.model.detailsTaskID = nil
            press("Delete \(linked.title)", in: rowRoot)
            require(!store.planner.tasks.contains { $0.id == linked.id }, "visible Delete persists removal")
            store.undo()
            require(
                store.planner.tasks.contains { $0.id == linked.id && $0.title == linked.title },
                "Undo restores the exact deleted task")
            require(store.planner.focus?.state != .running, "Undo deletion never restarts the timer")
            snapshot(rowRoot, "task-actions", into: output)

            // Textual priorities and multiline titles remain present at the narrow card width.
            for priority in [TaskPriority.high, .medium, .low] {
                var task = store.planner.tasks.first { $0.id == linked.id }!
                task.priority = priority
                task.title =
                    "Inspect every seed tray\nCheck the labels and record which seedlings need water before closing the greenhouse"
                rowWindow.setContentSize(NSSize(width: 280, height: 240))
                rowRoot.rootView = TaskRow(task: task).environmentObject(store).environmentObject(delegate.model)
                    .environment(\.accessibilityEnabled, true)
                await settle(); await wakeAX(); await settle()
                snapshot(rowRoot, "task-\(priority.rawValue)-narrow", into: output)
                recordAccessibility(rowRoot, "task-\(priority.rawValue)-narrow", into: output)
                require(
                    control("\(priority.rawValue.capitalized) priority", in: rowRoot) != nil,
                    "\(priority): priority is text, not color alone")
                guard let title = staticText(task.title, in: rowRoot) else {
                    require(false, "\(priority): full multiline title exposed"); return
                }
                require(frame(title).height > 28, "\(priority): long title actually wraps")
            }
            require(store.lastError == nil, "no store error during UI lifecycle")
            let report: [String: Any] = [
                "metrics": metrics,
                "keyboardActivation": keyboardVerified ? "verified-in-process-Tab-Space" : "unverified-on-this-runner",
                "activation": "real-own-process-AX-press-no-model-fallback",
                "taskActivation": "window-right-click-tracked-NSMenu-item-action",
                "screenshots": "own-window-cacheDisplay-not-compositor", "physicalNotch": "unverified",
                "voiceOverSpeech": "unverified",
                "lastRowKeyboardUndo": "verified-own-process-NotchPanel",
                "rowCustomActions": "verified-native-handlers-exact-task",
            ]
            try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
                to: output.appendingPathComponent("results.json"))
            print("Keyboard activation: \(report["keyboardActivation"]!)")
            print("Focus entry probes passed; no direct-model activation fallback.")
            exit(0)
        }
    }
    withExtendedLifetime(delegate) { app.run() }
}

// Deliberately authored fixture setup, not a production mutation entry point.
@MainActor
private extension PlannerStore {
    func seedFixture(_ body: (inout PlannerEngine) throws -> Void) {
        do {
            try file.mutate { planner in
                var engine = PlannerEngine(planner: planner)
                try body(&engine)
                planner = engine.planner
            }
            reloadFromDisk(external: false)
        } catch { lastError = .planner(error.perchPresentationDetail) }
    }
}
