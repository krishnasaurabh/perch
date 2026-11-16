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
            .padding(10).frame(width: size.width, height: size.height).background(Theme.lavender)
            .environment(\.colorScheme, .light))
    window.orderFrontRegardless()

    // Top edge (in points from the top) of planned-light and completed-dark pixels in today's column.
    @MainActor func frame(_ name: String) -> (planned: CGFloat?, completed: CGFloat?) {
        guard let view = window.contentView else { return (nil, nil) }
        let directory = output.appendingPathComponent("insights-bars")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("\(name).png")
        // cacheDisplay draws the model's final values, not the compositor's animated frame.
        // Capture only this synthetic borderless window, never the user's desktop.
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), path.path]
        do { try capture.run() } catch { require(false, "Chart window capture starts: \(error)") }
        capture.waitUntilExit()
        require(capture.terminationStatus == 0, "Chart window capture succeeds")
        guard let data = try? Data(contentsOf: path), let rep = NSBitmapImageRep(data: data) else {
            require(false, "Chart window capture decodes")
            return (nil, nil)
        }
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let inner = size.width - 20, col = (inner - 6 * 14) / 7
        let x = Int((10 + 6 * (col + 14) + col / 2) * scale)
        var planned: Int?, completed: Int?
        func rgb(_ value: UInt32) -> [Int] {
            [Int((value >> 16) & 255), Int((value >> 8) & 255), Int(value & 255)]
        }
        let plannedColor = rgb(ThemeTokens.chartPlanned)
        let completedColor = rgb(ThemeTokens.chartCompleted)
        func matches(_ pixel: [Int], _ target: [Int]) -> Bool {
            zip(pixel.prefix(3), target).allSatisfy { abs($0 - $1) < 5 }
        }
        require(rep.samplesPerPixel >= 3 && rep.bitsPerSample == 8, "Chart capture uses 8-bit RGB pixels")
        var pixel = [Int](repeating: 0, count: rep.samplesPerPixel)
        print("chart scan \(name): x=\(x), scale=\(scale), planned=\(plannedColor), completed=\(completedColor)")
        var plannedRun = 0, completedRun = 0
        // Scan only the plot: the day labels below the baseline are dark text too.
        for y in 0..<Int((size.height - 48) * scale) {
            rep.getPixel(&pixel, atX: x, y: y)
            plannedRun = matches(pixel, plannedColor) ? plannedRun + 1 : 0
            completedRun = matches(pixel, completedColor) ? completedRun + 1 : 0
            if completed == nil, completedRun >= 3 { completed = y - 2 }
            if planned == nil, plannedRun >= 3 { planned = y - 2 }
        }
        return (planned.map { CGFloat($0) / scale }, completed.map { CGFloat($0) / scale })
    }
    // Today is column 6 (780 ms stagger). Find the first compositor frame
    // containing BOTH series, rather than treating a missing series as growth.
    try? await Task.sleep(nanoseconds: 100_000_000)
    let initial = frame("initial")
    require(initial.planned != nil, "Planned is visible before completed growth")
    var early = initial
    let deadline = Date().addingTimeInterval(1.5)
    var sample = 0
    while early.completed == nil && Date() < deadline {
        try? await Task.sleep(nanoseconds: 25_000_000)
        sample += 1
        early = frame("growth-\(sample)")
    }
    require(early.completed != nil, "Completed is visible in the early frame")
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    let late = frame("settled")
    print(
        "bars frames: early planned \(early.planned as Any) completed \(early.completed as Any); late planned \(late.planned as Any) completed \(late.completed as Any)"
    )
    require(early.planned != nil && late.planned != nil, "Planned silhouette is visible in both frames")
    require(
        abs((initial.planned ?? 0) - (late.planned ?? 1)) <= 1
            && abs((early.planned ?? 0) - (late.planned ?? 1)) <= 1,
        "Planned stands at final height from the first frames")
    require(late.completed != nil, "Completed bar is drawn once grown")
    // y grows downward: both series must be present, with a lower Completed top edge early.
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
func axText(_ node: NSObject, _ name: String) -> String {
    let value = axObject(node, name)
    return (value as? String) ?? (value as? NSAttributedString)?.string ?? ""
}

@MainActor
func axRoots() -> [NSView] {
    NSApp.windows.compactMap { window in
        window is NotchPanel && window.isVisible ? window.contentView : nil
    }
}

@MainActor
func axNodes(_ root: NSObject) -> [NSObject] {
    var seen = Set<ObjectIdentifier>()
    func walk(_ node: NSObject, depth: Int) -> [NSObject] {
        guard depth < 60, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
        var children = ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"]
            .flatMap { (axObject(node, $0) as? [NSObject]) ?? [] }
        if let view = node as? NSView { children += view.subviews }
        return [node] + children.flatMap { walk($0, depth: depth + 1) }
    }
    return walk(root, depth: 0)
}

@MainActor
func axInventory() -> String {
    axRoots().flatMap { axNodes($0) }.map { node in
        let native: String
        if let button = node as? NSButton {
            native = "title=\(button.title)"
        } else if let field = node as? NSTextField {
            native = "editable=\(field.isEditable) placeholder=\(field.placeholderString ?? "nil")"
        } else {
            native = ""
        }
        return "\(type(of: node)) role=\(axText(node, "accessibilityRole")) "
            + "id=\(axText(node, "accessibilityIdentifier")) label=\(axText(node, "accessibilityLabel")) "
            + "value=\(axText(node, "accessibilityValue")) \(native)"
    }.joined(separator: "\n")
}

@MainActor
func findControl(_ label: String, attribute: String = "accessibilityLabel") -> NSObject? {
    func find(_ root: NSView) -> NSObject? {
        root.layoutSubtreeIfNeeded()
        return axNodes(root).first { node in
            if attribute == "accessibilityLabel" {
                if let field = node as? NSTextField, field.isEditable,
                    axText(field, "accessibilityLabel") == label || field.placeholderString == label
                {
                    return true
                }
                if let button = node as? NSButton,
                    button.title == label || axText(button, "accessibilityLabel") == label
                {
                    return true
                }
            }
            if attribute == "accessibilityIdentifier" {
                if let button = node as? NSButton, button.accessibilityIdentifier() == label { return true }
                if let field = node as? NSTextField, field.isEditable,
                    field.accessibilityIdentifier() == label
                {
                    return true
                }
            }
            return axText(node, attribute) == label
        }
    }
    for root in axRoots() {
        if let found = find(root) { return found }
    }
    return nil
}

@MainActor
func waitForControl(_ label: String, attribute: String = "accessibilityLabel") async -> NSObject? {
    for _ in 0..<100 {
        for root in axRoots() { root.layoutSubtreeIfNeeded() }
        if let found = findControl(label, attribute: attribute) { return found }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    print("AX inventory after missing \(attribute)=\(label):\n\(axInventory())")
    return nil
}

@MainActor
func pressControl(_ label: String, attribute: String = "accessibilityLabel") async {
    guard let node = await waitForControl(label, attribute: attribute) else {
        require(false, "button exists: \(label)")
        return
    }
    let selector = NSSelectorFromString("accessibilityPerformPress")
    guard node.responds(to: selector), let implementation = node.method(for: selector) else {
        require(false, "button supports press: \(label)\n\(axInventory())")
        return
    }
    typealias Press = @convention(c) (AnyObject, Selector) -> Bool
    require(unsafeBitCast(implementation, to: Press.self)(node, selector), "pressed real button: \(label)")
}

@MainActor
func requireChecklistRows(_ ids: [UUID], message: String) async {
    for id in ids {
        let row = await waitForControl("task-complete-\(id)", attribute: "accessibilityIdentifier")
        require(row != nil, "\(message): \(id)")
    }
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
            let emptyCount = await waitForControl("A fresh page")
            let checklist = await waitForControl("The checklist")
            require(emptyCount != nil && checklist != nil, "empty Today exposes one checklist and its empty count")
            require(
                findControl("To do 0") == nil && findControl("Completed 0") == nil,
                "empty Today has no legacy task tabs")
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
            require(try! delegate.store.file.load().tasks == delegate.store.planner.tasks, "capture persists on disk")
            require(captureEditor()?.string == "", "capture clears and stays focused after add")
            let populatedCount = await waitForControl("1 to do")
            require(populatedCount != nil, "single checklist counts the captured task")
            await requireChecklistRows(delegate.store.planner.tasks.map(\.id), message: "captured row is available")
            delegate.notch.snapshot(into: output.appendingPathComponent("today-populated"))

            let id = delegate.store.planner.tasks[0].id
            let completionID = "task-complete-\(id)"
            await pressControl(completionID, attribute: "accessibilityIdentifier")
            await settle()
            let persistedCompletion = try! delegate.store.file.load()
            require(
                delegate.store.planner.tasks.first { $0.id == id }?.done == true
                    && persistedCompletion.tasks.first { $0.id == id }?.done == true,
                "the real Complete button persists the exact captured task")
            require(
                delegate.store.engine.insights().allTimeCompleted == 1, "first completion records Insights progress")
            let firstCount = await waitForControl("1 of 1 done")
            let reopenOnly = await waitForControl("Reopen Capture probe task")
            require(firstCount != nil && reopenOnly != nil, "completion updates the single-list count and action")
            await requireChecklistRows([id], message: "completed captured row stays available")
            delegate.notch.snapshot(into: output.appendingPathComponent("today-cleared"))

            delegate.store.apply { try $0.addTasks(["Sort the seed packets", "Rinse the paint tray"]) }
            await settle()
            require(delegate.store.engine.tasks(on: .day(delegate.store.today)).count == 3, "three-task Today fixture")
            require(try! delegate.store.file.load().tasks.count == 3, "three-task fixture persists")
            let activeIDs = delegate.store.engine.tasks(on: .day(delegate.store.today)).filter { !$0.done }.map(\.id)
            let allIDs = [id] + activeIDs
            require(activeIDs.count == 2, "two active task controls are expected")
            let mixedCount = await waitForControl("1 of 3 done")
            require(mixedCount != nil, "single checklist counts open and completed tasks together")
            await requireChecklistRows(allIDs, message: "completed and active rows stay available together")
            require(
                findControl("Completed 1") == nil && findControl("To do 2") == nil,
                "populated checklist has no legacy task tabs")
            delegate.notch.snapshot(into: output.appendingPathComponent("today-three-one-completed"))
            let reopenCaptured = await waitForControl("Reopen Capture probe task")
            require(reopenCaptured != nil, "completed task exposes Reopen without changing lists")
            delegate.notch.snapshot(into: output.appendingPathComponent("today-single-checklist-completed"))

            await pressControl(completionID, attribute: "accessibilityIdentifier")
            await settle()
            let persistedReopen = try! delegate.store.file.load()
            require(
                delegate.store.planner.tasks.first { $0.id == id }?.done == false
                    && persistedReopen.tasks.first { $0.id == id }?.done == false,
                "the real Reopen button persists the exact captured task")
            require(
                activeIDs.allSatisfy { activeID in
                    persistedReopen.tasks.first { $0.id == activeID }?.done == false
                },
                "reopening preserves both active neighbors")
            let reopenedCount = await waitForControl("3 to do")
            let completeCaptured = await waitForControl("Complete Capture probe task")
            require(reopenedCount != nil && completeCaptured != nil, "reopening restores the open count and action")
            require(findControl("Reopen Capture probe task") == nil, "reopened task no longer offers Reopen")
            await requireChecklistRows(allIDs, message: "all rows remain available after reopening")
            delegate.notch.snapshot(into: output.appendingPathComponent("today-single-checklist-reopened"))

            await pressControl(completionID, attribute: "accessibilityIdentifier")
            await settle()
            let persistedSecondCompletion = try! delegate.store.file.load()
            require(
                persistedSecondCompletion.tasks.first { $0.id == id }?.done == true
                    && activeIDs.allSatisfy { activeID in
                        persistedSecondCompletion.tasks.first { $0.id == activeID }?.done == false
                    },
                "second real completion persists only the captured task")
            let secondCount = await waitForControl("1 of 3 done")
            require(secondCount != nil, "second completion restores the mixed count")
            await requireChecklistRows(allIDs, message: "all rows remain available after completing again")
            require(
                findControl("Completed 1") == nil && findControl("Complete Capture probe task") == nil
                    && findControl("Reopen Capture probe task") != nil,
                "second completion updates the row in place without tabs")
            delegate.store.seedFixture { engine in
                engine.planner.tasks = []
                _ = try engine.startStopwatch(taskID: nil)
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
                "today-three-one-completed", "today-single-checklist-completed", "today-single-checklist-reopened",
                "insights-focus-only",
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
        } catch { lastError = .planner(error.perchPresentationDetail) }
    }
}
