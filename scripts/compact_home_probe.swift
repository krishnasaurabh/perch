// Temporary CI entry point using the real controller/views and an isolated planner.
import AppKit
import PlannerCore
import SwiftUI
import ApplicationServices

@MainActor
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}
@MainActor
func settle() async { try? await Task.sleep(nanoseconds: 800_000_000) }
@MainActor
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

func wakeAX() async {
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
func attribute(_ node: NSObject, _ name: String) -> Any? {
    let selector = NSSelectorFromString(name)
    return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
}
@MainActor
func axNodes(_ root: NSObject) -> [NSObject] {
    var seen = Set<ObjectIdentifier>()
    func walk(_ node: NSObject) -> [NSObject] {
        guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
        return [node] + ((attribute(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(walk)
    }
    return walk(root)
}
@MainActor
func controlFrame(_ label: String, in root: NSView) -> CGRect? {
    guard let node = axNodes(root).first(where: { attribute($0, "accessibilityLabel") as? String == label }),
        let value = node.value(forKey: "accessibilityFrame") as? NSValue
    else { return nil }
    return value.rectValue
}
@MainActor
func snapshot(_ root: NSView, _ name: String, into output: URL) {
    root.layoutSubtreeIfNeeded()
    let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
    root.cacheDisplay(in: root.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["COMPACT_HOME_OUTPUT"]!)
    let baseline = ProcessInfo.processInfo.environment["COMPACT_HOME_BASELINE"] == "1"
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        Task { @MainActor in
            var metrics: [[String: Any]] = []
            let geometryOnly = ProcessInfo.processInfo.environment["COMPACT_HOME_GEOMETRY_ONLY"] == "1"
            if !geometryOnly {
                for scenario in ["empty", "three", "timer", "long-title", "dense", "timer-notepad"] {
                    delegate.model.close()
                    delegate.store.apply { e in
                        e.planner.tasks = []
                        e.planner.focus = nil
                        e.planner.preferences.hiddenWorkspaceCards = ["notepad"]
                        if scenario != "empty" {
                            let titles =
                                scenario == "long-title"
                                ? [
                                    String(
                                        repeating:
                                            "Review the launch checklist and verify the release handoff details. ",
                                        count: 5)
                                ]
                                : (1...(scenario == "dense" ? 24 : 3)).map {
                                    "Review item \($0) for the release checklist"
                                }
                            _ = try e.addTasks(titles, on: .day(e.today))
                        }
                        if scenario == "timer" || scenario == "timer-notepad" {
                            _ = try e.startTimer(task: e.planner.tasks[0].id.uuidString, minutes: 45)
                            try e.pauseTimer()
                        }
                        if scenario == "timer-notepad" { e.planner.preferences.hiddenWorkspaceCards = [] }
                    }
                    NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.home)
                    await settle()
                    guard let panel = NSApp.keyWindow, let root = panel.contentView,
                        let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor,
                        let geometry = delegate.model.geometry
                    else {
                        require(false, "\(scenario): capture editor is focused"); return
                    }
                    let workspace = geometry.workspace
                    let shell = workspace.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
                    let capture = editor.convert(editor.visibleRect, to: nil)
                    if baseline {
                        metrics.append([
                            "scenario": scenario, "workspaceHeight": workspace.height,
                            "capture": NSStringFromRect(capture),
                        ])
                        delegate.notch.snapshot(into: output.appendingPathComponent(scenario))
                        continue
                    }
                    require(
                        shell.insetBy(dx: 1, dy: 1).contains(capture), "\(scenario): capture fully inside compact shell"
                    )
                    require(
                        abs(
                            workspace.height
                                - WorkspaceLayout.preferredSize(notchHeight: geometry.notchSize.height).height) < 1,
                        "\(scenario): actual geometry uses the compact budget")
                    let lists = descendants(root).compactMap { $0 as? NSScrollView }.filter {
                        $0.documentView !== editor && $0.frame.height > 70 && $0.frame.width > 100
                    }
                    require(!lists.isEmpty, "\(scenario): bounded task scroll viewport exists")
                    // Pick the leftmost scroll view (the task list), excluding the field editor's own scroll view.
                    let list = lists.min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }!
                    let listFrame = list.convert(list.bounds, to: nil)
                    require(shell.contains(listFrame), "\(scenario): scroll viewport stays inside shell")
                    require(!listFrame.intersects(capture), "\(scenario): task scroll cannot cover capture")
                    require(
                        listFrame.height <= WorkspaceLayout.contentHeight, "\(scenario): task scroll height is bounded")
                    metrics.append([
                        "scenario": scenario, "workspaceHeight": workspace.height,
                        "capture": NSStringFromRect(capture), "taskViewport": NSStringFromRect(listFrame),
                        "taskDocumentHeight": list.documentView?.frame.height ?? 0,
                    ])
                    delegate.notch.snapshot(into: output.appendingPathComponent(scenario))
                    if scenario == "dense", let document = list.documentView {
                        require(
                            document.frame.height > list.contentSize.height,
                            "dense: content scrolls instead of growing shell")
                        document.scroll(NSPoint(x: 0, y: document.frame.height))
                        await settle()
                        require(
                            editor.convert(editor.visibleRect, to: nil) == capture,
                            "dense: capture does not move when tasks scroll")
                        delegate.notch.snapshot(into: output.appendingPathComponent("dense-scrolled"))
                    }
                    if scenario == "long-title" {
                        editor.insertText(
                            String(repeating: "A multi-line capture draft with more release notes. ", count: 12),
                            replacementRange: NSRange(location: NSNotFound, length: 0))
                        await settle()
                        require(
                            delegate.model.geometry?.workspace == workspace && panel.frame == geometry.window,
                            "typing never resizes the workspace")
                        delegate.notch.snapshot(into: output.appendingPathComponent("multiline-capture"))
                        let visibleCapture = editor.convert(editor.visibleRect, to: nil)
                        print("multi-line document=\(editor.bounds) visible=\(visibleCapture) shell=\(shell)")
                        require(
                            visibleCapture.height >= 12 && shell.contains(visibleCapture),
                            "multi-line capture viewport remains fully visible")
                    }
                }
                delegate.model.page = .insights
                await settle()
                delegate.notch.snapshot(into: output.appendingPathComponent("momentum"))
            }
            if !baseline {
                delegate.model.close()
                delegate.model.page = .home
                // Same real Home at both supported widths, including its narrower running-focus column.
                for width in [CGFloat(820), CGFloat(620)] {
                    for running in [false, true] {
                        delegate.store.apply { e in
                            e.planner.tasks = []; e.planner.focus = nil
                            e.planner.preferences.hiddenWorkspaceCards = ["notepad"]
                            if running { _ = try e.startTimer(task: nil, minutes: 45) }
                        }
                        let name = "width-\(Int(width))-\(running ? "running" : "resting")"
                        let window = NSWindow(
                            contentRect: CGRect(x: 30, y: 100, width: width, height: 351),
                            styleMask: [.titled], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        let root = NSHostingView(
                            rootView: WorkspaceView(notchHeight: 0)
                                .environmentObject(delegate.store).environmentObject(delegate.model).environmentObject(
                                    delegate.services
                                )
                                .environment(\.colorScheme, .dark).background(Color.black))
                        window.contentView = root
                        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                        await settle(); await wakeAX(); await settle()
                        require(axNodes(root).count > 10, "\(name): AX populated before bounds checks")
                        guard let capture = controlFrame("Add a task", in: root) else {
                            require(false, "\(name): capture bounds exist"); return
                        }
                        let entry = controlFrame("Start focus", in: root)
                        require(running ? entry == nil : entry != nil, "\(name): expected Start focus visibility")
                        @MainActor func taskList() -> NSScrollView {
                            descendants(root).compactMap { $0 as? NSScrollView }
                                .filter { $0.frame.height > 70 && $0.frame.width > 100 }
                                .min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }!
                        }
                        @MainActor func fade() -> NSView? {
                            descendants(taskList()).first { $0.identifier?.rawValue == "today-continuation-fade" }
                        }
                        if !geometryOnly {
                            require(fade() != nil && fade()!.isHidden, "\(name): no fade when empty")
                        }
                        delegate.store.apply { try $0.addTasks(["Inspect one short checklist"], on: .day($0.today)) }
                        await settle()
                        if !geometryOnly { require(fade()!.isHidden, "\(name): no fade for fitting rows") }
                        delegate.store.apply { e in
                            e.planner.tasks = []
                            _ = try e.addTasks(
                                (1...24).map {
                                    "Inspect release group \($0)\nVerify the checklist notes and handoff details for this group"
                                }, on: .day(e.today), literal: true)
                        }
                        require(
                            delegate.store.planner.tasks.count == 24
                                && delegate.store.planner.tasks.allSatisfy { $0.title.contains("\n") },
                            "\(name): fixture retains 24 actual multiline titles")
                        await settle(); await wakeAX(); await settle()
                        let list = taskList(), document = taskList().documentView!
                        require(
                            document.frame.height > list.contentSize.height, "\(name): multiline dense rows overflow")
                        require(controlFrame("Add a task", in: root) == capture, "\(name): dense capture unchanged")
                        let denseEntry = controlFrame("Start focus", in: root)
                        require(
                            running ? denseEntry == nil : denseEntry != nil,
                            "\(name): dense Start focus visibility unchanged")
                        require(document.frame.height / 24 > 40, "\(name): rendered rows occupy multiple lines")
                        if !geometryOnly {
                            guard let cue = fade() else {
                                require(false, "\(name): continuation cue installed"); return
                            }
                            require(!cue.isHidden, "\(name): fade visible during overflow")
                            require(
                                cue.frame.height == 20 && list.bounds.contains(cue.frame),
                                "\(name): short cue contained in viewport")
                            require(cue.hitTest(NSPoint(x: 4, y: 4)) == nil, "\(name): cue does not intercept clicks")
                        }
                        snapshot(root, name + "-dense", into: output)
                        document.scroll(
                            NSPoint(x: 0, y: document.isFlipped ? document.bounds.maxY : document.bounds.minY))
                        await settle()
                        let visible = document.convert(list.contentView.bounds, from: list.contentView)
                        require(
                            document.isFlipped
                                ? visible.maxY >= document.bounds.maxY - 1 : visible.minY <= document.bounds.minY + 1,
                            "\(name): actual scroll end reached")
                        if !geometryOnly { require(fade()!.isHidden, "\(name): fade absent at scroll end") }
                        require(controlFrame("Add a task", in: root) == capture, "\(name): scroll capture unchanged")
                        require(
                            controlFrame("Start focus", in: root) == denseEntry, "\(name): scroll Start focus unchanged"
                        )
                        snapshot(root, name + "-end", into: output)
                        metrics.append([
                            "scenario": name, "capture": NSStringFromRect(capture),
                            "startFocus": denseEntry.map(NSStringFromRect) ?? "absent",
                            "taskViewport": NSStringFromRect(list.convert(list.bounds, to: nil)),
                        ])
                        // Shrinking content must also clear the cue without any user scroll.
                        delegate.store.apply { $0.planner.tasks = [] }
                        await settle()
                        if !geometryOnly { require(fade()!.isHidden, "\(name): fade clears after content removal") }
                        window.orderOut(nil)
                    }
                }
            }
            let data = try! JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
            try! data.write(to: output.appendingPathComponent("layout-metrics.json"))
            print("Compact Home layout probes passed.")
            exit(0)
        }
    }
    withExtendedLifetime(delegate) { app.run() }
}
