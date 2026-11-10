// Replaces App/main.swift only in the temporary CI probe package. Uses the actual views/controller.
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
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
    print("PASS: \(message)")
}

@MainActor
func settle() async {
    try? await Task.sleep(nanoseconds: 900_000_000)
}

@MainActor
func captureEditor() -> NSTextView? {
    // Unlike the notepad's NSTextView, a TextField uses the window's field editor.
    guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
    return editor
}

/// Insights chart motion and scale (F07/F11). Pure checks on the WeekBars rules, then real rendered frames of a
/// hosted WeekBars: Planned must already stand at final height on the first frames, Completed must still be on the
/// baseline and then grow. Frames are written next to the snapshots as evidence.
@MainActor
func probeWeekBars(_ focusOnly: Insights, output: URL) async {
    // Rules.
    require(WeekBars.height(.planned, final: 50, grown: false) == 50, "Planned is at final height before growth")
    require(WeekBars.height(.completed, final: 50, grown: false) == 0, "Completed starts on the baseline")
    require(WeekBars.height(.completed, final: 50, grown: true) == 50, "Completed reaches its final height")
    for i in 0..<7 {
        require(
            WeekBars.growth(.planned, index: i, policy: MotionPolicy(reduceMotion: false)) == nil,
            "Planned bar \(i) has no animation")
        require(
            WeekBars.growth(.completed, index: i, policy: MotionPolicy(reduceMotion: false)) != nil,
            "Completed bar \(i) animates")
        require(
            WeekBars.growth(.completed, index: i, policy: MotionPolicy(reduceMotion: true)) == nil,
            "Reduce Motion: Completed bar \(i) does not animate")
    }
    require(
        WeekBars.growth(.completed, index: 3, policy: MotionPolicy(reduceMotion: false))
            == Motion.bar.delay(3 * Motion.barStagger),
        "Completed keeps the bars token and 130 ms stagger")
    require(WeekBars.scaleLabel(top: 1, metric: .focus) == "1m", "focus-only scale names one minute")
    require(
        WeekBars.scaleLabel(top: 5, metric: .tasks) == "5 tasks"
            && WeekBars.scaleLabel(top: 1, metric: .tasks) == "1 task",
        "task scale names the top value")
    let focusTop = max(1, focusOnly.lastSeven.map { $0.focusSeconds / 60 }.max() ?? 1)
    require(WeekBars.scaleLabel(top: focusTop, metric: .focus) == "1m", "probe focus-only week tops out at 1m")

    // Rendered frames: today has 4 planned, 1 completed.
    var engine = PlannerEngine(planner: Planner())
    let added = (try? engine.addTasks(["a", "b", "c", "d"])) ?? []
    _ = try? engine.complete(added[0].id)
    let insights = engine.insights()
    require(
        insights.lastSeven.last?.planned == 4 && insights.lastSeven.last?.completed == 1, "frame fixture: 1 of 4 today")
    let size = NSSize(width: 420, height: 240)
    let window = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size), styleMask: [.borderless],
        backing: .buffered, defer: false)
    window.contentView = NSHostingView(
        rootView:
            WeekBars(days: insights.lastSeven, metric: .tasks, today: engine.today)
            .padding(10).frame(width: size.width, height: size.height).background(Color.white))
    window.orderFrontRegardless()

    // Top edge (in points from the top) of planned-grey and completed-dark pixels in today's column.
    func frame(_ name: String) -> (planned: CGFloat?, completed: CGFloat?) {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return (nil, nil)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(
                at: output.appendingPathComponent("insights-bars"), withIntermediateDirectories: true)
            try? png.write(to: output.appendingPathComponent("insights-bars/\(name).png"))
        }
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let inner = size.width - 20, col = (inner - 6 * 14) / 7
        let x = Int((10 + 6 * (col + 14) + col / 2) * scale)
        var planned: Int?, completed: Int?
        // Scan only the plot: the day labels below the baseline are dark text too.
        for y in 0..<Int((size.height - 48) * scale) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let v = (c.redComponent + c.greenComponent + c.blueComponent) / 3
            if completed == nil, v < 0.3 { completed = y }
            if planned == nil, v > 0.6, v < 0.9 { planned = y }
        }
        return (planned.map { CGFloat($0) / scale }, completed.map { CGFloat($0) / scale })
    }
    // Today is column 6: 780 ms of stagger before it starts, so ~100 ms in it must still be on the baseline.
    try? await Task.sleep(nanoseconds: 100_000_000)
    let early = frame("t0100ms")
    try? await Task.sleep(nanoseconds: 2_400_000_000)
    let late = frame("t2500ms")
    print(
        "bars frames: early planned \(early.planned as Any) completed \(early.completed as Any); late planned \(late.planned as Any) completed \(late.completed as Any)"
    )
    require(early.planned != nil && late.planned != nil, "Planned silhouette is visible in both frames")
    require(
        abs((early.planned ?? 0) - (late.planned ?? 1)) <= 1, "Planned stands at final height from the first frames")
    require(late.completed != nil, "Completed bar is drawn once grown")
    // y grows downward: an absent or lower top edge early means Completed had not grown yet.
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        print("note: Reduce Motion is on for this runner; Completed is expected at final height immediately")
    } else {
        require((early.completed ?? .infinity) > (late.completed ?? 0) + 10, "Completed grows after the chart appears")
    }
    window.orderOut(nil)
}

// Exercise the real SwiftUI buttons, not a test-only tab setter. SwiftUI creates
// its AX tree lazily, so ask for our own windows off-main before traversing it.
func wakeAccessibility() async {
    await Task.detached {
        let app = AXUIElementCreateApplication(getpid())
        var value: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        for window in (value as? [AXUIElement]) ?? [] {
            var children: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children)
        }
    }.value
}

@MainActor
func axObject(_ node: NSObject, _ name: String) -> Any? {
    let selector = NSSelectorFromString(name)
    return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
}

@MainActor
func findControl(_ label: String) -> NSObject? {
    func find(_ node: NSObject, depth: Int) -> NSObject? {
        guard depth < 60 else { return nil }
        if axObject(node, "accessibilityLabel") as? String == label { return node }
        for child in (axObject(node, "accessibilityChildren") as? [NSObject]) ?? [] {
            if let found = find(child, depth: depth + 1) { return found }
        }
        return nil
    }
    for window in NSApp.windows where window is NotchPanel && window.isVisible {
        if let root = window.contentView, let found = find(root, depth: 0) { return found }
    }
    return nil
}

@MainActor
func pressControl(_ label: String) {
    guard let node = findControl(label) else { require(false, "button exists: \(label)"); return }
    let selector = NSSelectorFromString("accessibilityPerformPress")
    guard node.responds(to: selector), let implementation = node.method(for: selector) else {
        require(false, "button supports press: \(label)"); return
    }
    typealias Press = @convention(c) (AnyObject, Selector) -> Bool
    require(unsafeBitCast(implementation, to: Press.self)(node, selector), "pressed real button: \(label)")
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EMPTY_STATES_OUTPUT"]!)

    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        Task { @MainActor in
            require(delegate.store.planner.tasks.isEmpty, "isolated planner starts empty")
            require(!delegate.model.expanded, "normal launch starts closed")
            delegate.store.updatePrefs {
                $0.catchCopies = false; $0.catchScreenshots = false
            }
            // A passive reveal must leave another window's editor alone.
            let other = NSPanel(
                contentRect: NSRect(x: 80, y: 80, width: 180, height: 80),
                styleMask: [.titled], backing: .buffered, defer: false)
            let otherField = NSTextField(frame: NSRect(x: 10, y: 10, width: 160, height: 24))
            other.contentView?.addSubview(otherField)
            NSApp.activate(ignoringOtherApps: true)
            other.makeKeyAndOrderFront(nil)
            other.makeFirstResponder(otherField)
            await settle()
            require(other.isKeyWindow, "passive-focus fixture starts as the key window")
            delegate.model.open()
            await settle()
            require(other.isKeyWindow, "passive reveal preserves another window's keyboard focus")
            require(delegate.model.captureFocusRequest == nil, "passive reveal does not request capture")
            delegate.model.close()
            await settle()
            other.orderOut(nil)
            NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.home)
            await settle()
            require(captureEditor() != nil, "Today opening focuses a text field")
            NSApp.keyWindow?.makeFirstResponder(nil)
            require(captureEditor() == nil, "capture can yield focus to another control")
            NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.home)
            await settle()
            require(captureEditor() != nil, "explicit opening refocuses an already-open Today")
            await wakeAccessibility()
            await settle()
            require(findControl("To do 0") != nil, "empty Today exposes To do")
            require(findControl("Completed 0") == nil, "empty Today hides Completed 0")
            delegate.notch.snapshot(into: output.appendingPathComponent("today-empty"))

            for page in [NotchPage.week, .clips] {
                delegate.model.page = page
                await settle()
                delegate.notch.snapshot(into: output.appendingPathComponent("\(page.rawValue)-empty"))
            }
            // Page switch and full close/reopen both remount the composer.
            delegate.model.page = .home
            await settle()
            require(captureEditor() != nil, "returning to Today focuses capture")
            delegate.model.close()
            await settle()
            NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.home)
            await settle()
            require(captureEditor() != nil, "reopening focuses capture")

            captureEditor()?.insertText(
                "Capture probe task", replacementRange: NSRange(location: NSNotFound, length: 0))
            await settle()
            require(captureEditor()?.string == "Capture probe task", "typing without a click reaches capture")
            if let window = NSApp.keyWindow,
                let enter = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\r",
                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
            {
                NSApp.sendEvent(enter)
            }
            await settle()
            require(delegate.store.planner.tasks.count == 1, "Return creates one task")
            require(delegate.store.planner.tasks.first?.title == "Capture probe task", "capture text is persisted")
            require(captureEditor()?.string == "", "capture clears and stays focused after add")
            delegate.notch.snapshot(into: output.appendingPathComponent("today-populated"))

            let id = delegate.store.planner.tasks[0].id
            delegate.store.apply { try $0.complete(id) }
            await settle()
            delegate.notch.snapshot(into: output.appendingPathComponent("today-cleared"))
            require(
                delegate.store.engine.insights().allTimeCompleted == 1, "first completion records Insights progress")
            delegate.store.apply { try $0.addTasks(["Sort the seed packets", "Rinse the paint tray"]) }
            await settle()
            require(delegate.store.engine.tasks(on: .day(delegate.store.today)).count == 3, "three-task Today fixture")
            require(findControl("Completed 1") != nil, "first completion makes Completed reachable")
            delegate.notch.snapshot(into: output.appendingPathComponent("today-three-one-completed"))
            pressControl("Completed 1")
            await settle()
            require(
                findControl("Uncheck task") != nil && findControl("Check off task") == nil,
                "Completed shows only the finished row")
            delegate.notch.snapshot(into: output.appendingPathComponent("today-completed-tab"))
            pressControl("Uncheck task")
            await settle()
            require(
                findControl("Completed 0") == nil && findControl("To do 3") != nil,
                "reopening the last completion hides its pill")
            require(findControl("Check off task") != nil, "last completion reopened: To do rows are visible")
            delegate.notch.snapshot(into: output.appendingPathComponent("today-tab-fallback"))
            delegate.store.apply { try $0.complete(id) }
            await settle()
            require(
                findControl("Completed 1") != nil && findControl("Check off task") != nil
                    && findControl("Uncheck task") == nil,
                "a new completion does not resurrect the hidden tab selection")
            delegate.store.seedFixture { engine in
                engine.planner.tasks = []
                _ = engine.startStopwatch(taskID: nil)
                let later = Date().addingTimeInterval(60)
                engine.now = { later }
                _ = engine.stopTimer()
            }
            await settle()
            let focusOnly = delegate.store.engine.insights()
            require(
                focusOnly.allTimeCompleted == 0 && focusOnly.allTimeFocusSeconds > 0,
                "focus alone is Insights progress without a completed task")
            // Insights is its own page now (w3/ui-home-clean), so the focus-only state is captured there.
            delegate.model.page = .insights
            await settle()
            delegate.notch.snapshot(into: output.appendingPathComponent("insights-focus-only"))
            await probeWeekBars(focusOnly, output: output)
            delegate.model.page = .home
            require(delegate.store.lastError == nil, "empty-state transitions report no store error")
            for symbol in ["square.and.pencil", "checkmark.circle", "calendar", "tray", "paperclip", "chart.bar"] {
                require(
                    NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                    "SF Symbol exists: \(symbol)")
            }
            for name in [
                "today-empty", "week-empty", "clips-empty", "today-populated", "today-cleared",
                "today-three-one-completed", "today-completed-tab", "today-tab-fallback", "insights-focus-only",
            ] {
                let files =
                    (try? FileManager.default.contentsOfDirectory(
                        at: output.appendingPathComponent(name),
                        includingPropertiesForKeys: nil)) ?? []
                require(
                    files.contains { $0.pathExtension == "png" && NSImage(contentsOf: $0) != nil },
                    "snapshot exists and decodes: \(name)")
            }
            print("Empty-state and capture smoke passed. Snapshots: \(output.path)")
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
        } catch { lastError = error.localizedDescription }
    }
}
