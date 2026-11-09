// Temporary CI entry point using the real controller/views and an isolated planner.
import AppKit
import PlannerCore

@MainActor
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}
@MainActor
func settle() async { try? await Task.sleep(nanoseconds: 800_000_000) }
@MainActor
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

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
            for scenario in ["empty", "three", "timer", "long-title", "dense", "timer-notepad"] {
                delegate.model.close()
                delegate.store.apply { e in
                    e.planner.tasks = []
                    e.planner.focus = nil
                    e.planner.preferences.hiddenWorkspaceCards = ["notepad"]
                    if scenario != "empty" {
                        let titles = scenario == "long-title"
                            ? [String(repeating: "Review the launch checklist and verify the release handoff details. ", count: 5)]
                            : (1...(scenario == "dense" ? 24 : 3)).map { "Review item \($0) for the release checklist" }
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
                      let geometry = delegate.model.geometry else {
                    require(false, "\(scenario): capture editor is focused"); return
                }
                let workspace = geometry.workspace
                let shell = workspace.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
                let capture = editor.convert(editor.visibleRect, to: nil)
                if baseline {
                    metrics.append(["scenario": scenario, "workspaceHeight": workspace.height,
                                    "capture": NSStringFromRect(capture)])
                    delegate.notch.snapshot(into: output.appendingPathComponent(scenario))
                    continue
                }
                require(shell.insetBy(dx: 1, dy: 1).contains(capture), "\(scenario): capture fully inside compact shell")
                require(abs(workspace.height - WorkspaceLayout.preferredSize(notchHeight: geometry.notchSize.height).height) < 1,
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
                require(listFrame.height <= WorkspaceLayout.contentHeight, "\(scenario): task scroll height is bounded")
                metrics.append(["scenario": scenario, "workspaceHeight": workspace.height,
                                "capture": NSStringFromRect(capture), "taskViewport": NSStringFromRect(listFrame),
                                "taskDocumentHeight": list.documentView?.frame.height ?? 0])
                delegate.notch.snapshot(into: output.appendingPathComponent(scenario))
                if scenario == "dense", let document = list.documentView {
                    require(document.frame.height > list.contentSize.height, "dense: content scrolls instead of growing shell")
                    document.scroll(NSPoint(x: 0, y: document.frame.height))
                    await settle()
                    require(editor.convert(editor.visibleRect, to: nil) == capture, "dense: capture does not move when tasks scroll")
                    delegate.notch.snapshot(into: output.appendingPathComponent("dense-scrolled"))
                }
                if scenario == "long-title" {
                    editor.insertText(String(repeating: "A multi-line capture draft with more release notes. ", count: 12),
                                      replacementRange: NSRange(location: NSNotFound, length: 0))
                    await settle()
                    require(delegate.model.geometry?.workspace == workspace && panel.frame == geometry.window, "typing never resizes the workspace")
                    delegate.notch.snapshot(into: output.appendingPathComponent("multiline-capture"))
                    let visibleCapture = editor.convert(editor.visibleRect, to: nil)
                    print("multi-line document=\(editor.bounds) visible=\(visibleCapture) shell=\(shell)")
                    require(visibleCapture.height >= 12 && shell.contains(visibleCapture), "multi-line capture viewport remains fully visible")
                }
            }
            delegate.model.page = .insights
            await settle()
            delegate.notch.snapshot(into: output.appendingPathComponent("momentum"))
            let data = try! JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
            try! data.write(to: output.appendingPathComponent("layout-metrics.json"))
            print("Compact Home layout probes passed.")
            exit(0)
        }
    }
    withExtendedLifetime(delegate) { app.run() }
}
