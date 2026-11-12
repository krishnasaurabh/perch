// Temporary CI entry point using the real controller/views and an isolated planner.
import AppKit
@testable import PlannerCore
#if canImport(PerchApp)
    @testable import PerchApp
    import PerchUI
    import PerchMCP
#endif
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

@MainActor
func recordFocus(delegate: AppDelegate, scenario: String, output: URL) {
    let state: [String: Any] = [
        "scenario": scenario,
        "expanded": delegate.model.expanded,
        "captureRequest": delegate.model.captureFocusRequest?.uuidString ?? "none",
        "windows": NSApp.windows.map { window -> [String: Any] in
            [
                "key": window.isKeyWindow,
                "visible": window.isVisible,
                "firstResponder": String(describing: window.firstResponder),
                "captureFrame": window.contentView.flatMap { controlFrame("Add a task", in: $0) }
                    .map(NSStringFromRect) ?? "missing",
            ]
        },
    ]
    try! JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]).write(
        to: output.appendingPathComponent("capture-focus-\(scenario).json"))
    delegate.notch.snapshot(into: output.appendingPathComponent("capture-focus-\(scenario)"))
}

/// The exact condition the scenario guard asserts: the key window's first responder is a field editor.
@MainActor
func captureEditorFocused(_ delegate: AppDelegate) -> Bool {
    guard let panel = NSApp.keyWindow, panel.contentView != nil,
        let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor, delegate.model.geometry != nil
    else { return false }
    return true
}

func address(_ object: AnyObject?) -> String {
    object.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
}

func rounded(_ seconds: Double) -> Double { (seconds * 1000).rounded() / 1000 }

/// Focus can briefly enter an incoming field before its layout finishes. Require continuous native
/// ownership, not the first positive sample. The deadline and the original focus assertion stay strict.
struct CaptureFocusReadiness {
    static let minimumSettle = 0.8
    static let stableInterval = 0.3
    static let deadline = 3.0
    private var candidateSince: Double?
    private var candidateEditor: String?
    private(set) var settledFocusAt: Double?
    private(set) var lostAfterFocus = false

    mutating func observe(time: Double, editorIdentity: String?, editingEndedAt: Double?) {
        // A begin/end transition can happen between samples, even if the same shared editor returns.
        if let editingEndedAt, let candidateSince, editingEndedAt >= candidateSince {
            self.candidateSince = nil
            candidateEditor = nil
            if settledFocusAt != nil { lostAfterFocus = true }
        }
        guard let editorIdentity else {
            candidateSince = nil
            candidateEditor = nil
            if settledFocusAt != nil { lostAfterFocus = true }
            return
        }
        if candidateEditor != editorIdentity {
            if settledFocusAt != nil { lostAfterFocus = true }
            candidateEditor = editorIdentity
            candidateSince = time
        }
        if settledFocusAt == nil, let candidateSince,
            time >= Self.minimumSettle, time <= Self.deadline,
            time - candidateSince >= Self.stableInterval
        {
            settledFocusAt = time
        }
    }
}

/// Exclude an outgoing editor while the explicit open is still being processed. Inspect the current
/// native owner without requesting focus or changing the window's key status.
@MainActor
func captureEditorIdentity(_ delegate: AppDelegate) -> String? {
    guard captureEditorFocused(delegate), delegate.model.expanded, delegate.model.captureFocusRequest != nil,
        let panel = NSApp.keyWindow, let root = panel.contentView,
        let editor = panel.firstResponder as? NSTextView, let field = editor.delegate as? NSTextField,
        field.window === panel, field.currentEditor() === editor,
        field.isDescendant(of: root), field.isEditable, !field.isHiddenOrHasHiddenAncestor
    else { return nil }
    return address(field)
}

/// One focus sample: app activation, key window, the panel's first responder and which editable field owns
/// the field editor (an outgoing workspace can still contribute a second capture field).
@MainActor
func focusState(_ delegate: AppDelegate) -> [String: Any] {
    let panel = NSApp.windows.first { $0 is NotchPanel && $0.isVisible }
    let editor = panel?.firstResponder as? NSTextView
    let owner = editor.flatMap { $0.isFieldEditor ? $0.delegate as? NSTextField : nil }
    let fields =
        panel?.contentView.map { descendants($0).compactMap { $0 as? NSTextField }.filter { $0.isEditable } } ?? []
    return [
        "appActive": NSApp.isActive,
        "appKeyWindow": NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil",
        "appKeyIsPanel": panel != nil && NSApp.keyWindow === panel,
        "panelIsKey": panel?.isKeyWindow ?? false,
        "firstResponder": panel?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil",
        "fieldEditor": editor?.isFieldEditor ?? false,
        "editorOwner": address(owner),
        "editableFields": fields.map {
            address($0) + " " + NSStringFromRect($0.convert($0.bounds, to: nil))
                + ($0.isHiddenOrHasHiddenAncestor ? " hidden" : "")
        },
        "expanded": delegate.model.expanded,
        "captureRequest": delegate.model.captureFocusRequest != nil,
        "page": String(describing: delegate.model.page),
        "guard": captureEditorFocused(delegate),
    ]
}

/// Timestamped key, activation and editing notifications for one explicit open.
@MainActor
final class FocusTrace {
    private let start = ProcessInfo.processInfo.systemUptime
    private(set) var events: [[String: Any]] = []
    private(set) var editingEndedAt: Double?
    private var observers: [NSObjectProtocol] = []
    var elapsed: Double { ProcessInfo.processInfo.systemUptime - start }

    init() {
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSText.didBeginEditingNotification, NSText.didEndEditingNotification,
            NSControl.textDidBeginEditingNotification, NSControl.textDidEndEditingNotification,
        ]
        for name in names {
            let raw = name.rawValue
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let object = note.object.map { String(describing: type(of: $0)) } ?? "nil"
                    MainActor.assumeIsolated { self?.record(raw, object) }
                })
        }
    }

    func record(_ name: String, _ object: String) {
        let time = elapsed
        events.append(["t": rounded(time), "event": name, "object": object])
        if name == NSText.didEndEditingNotification.rawValue
            || name == NSControl.textDidEndEditingNotification.rawValue
        {
            editingEndedAt = time
        }
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }
}

/// Every traced open, rewritten after each one so an early exit keeps the diagnostics.
@MainActor
enum FocusTraceLog {
    static var opens: [[String: Any]] = []
    static func append(_ open: [String: Any], output: URL) {
        opens.append(open)
        try! JSONSerialization.data(withJSONObject: opens, options: [.prettyPrinted, .sortedKeys]).write(
            to: output.appendingPathComponent("capture-focus-trace.json"))
    }
}

/// Observes the real explicit-open path without assigning focus. Allow at most 3 s for 300 ms of
/// continuous native capture ownership after the usual 0.8 s minimum; dense opens trace the full deadline.
@MainActor
func openHomeTraced(_ delegate: AppDelegate, label: String, full: Bool) async -> [String: Any] {
    let trace = FocusTrace()
    var samples: [[String: Any]] = []
    var firstFocused: Double?
    var focusedAtSettle: Bool?
    var readiness = CaptureFocusReadiness()
    var focused = false
    NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.home)
    while true {
        var state = focusState(delegate)
        let identity = captureEditorIdentity(delegate)
        let t = trace.elapsed
        focused = identity != nil
        state["t"] = rounded(t)
        state["captureOwner"] = identity ?? "nil"
        samples.append(state)
        if focused && firstFocused == nil { firstFocused = t }
        if t >= CaptureFocusReadiness.minimumSettle && focusedAtSettle == nil { focusedAtSettle = focused }
        readiness.observe(time: t, editorIdentity: identity, editingEndedAt: trace.editingEndedAt)
        if t >= CaptureFocusReadiness.deadline || (!full && readiness.settledFocusAt != nil) { break }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    trace.stop()
    let first = firstFocused.map { String(format: "%.3f", $0) } ?? "never"
    let summary =
        "TRACE \(label): firstFocused=\(first) focusedAt0.8s=\(focusedAtSettle ?? false) "
        + "focusedAtEnd=\(focused) lostAfterFocus=\(readiness.lostAfterFocus) end=\(String(format: "%.3f", trace.elapsed))\n"
    FileHandle.standardError.write(Data(summary.utf8))
    return [
        "label": label, "firstFocusedAt": first, "focusedAt800ms": focusedAtSettle ?? false,
        "focusedAtEnd": focused, "lostAfterFocus": readiness.lostAfterFocus, "end": rounded(trace.elapsed),
        "settledFocusAt": readiness.settledFocusAt.map(rounded) ?? -1,
        "samples": samples, "events": trace.events,
    ]
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
                for scenario in ["empty", "three", "completed", "timer", "long-title", "dense", "timer-notepad"] {
                    delegate.model.close()
                    delegate.store.seedFixture { e in
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
                            if scenario == "completed" {
                                for task in e.planner.tasks { _ = try e.complete(task.id) }
                            }
                        }
                        if scenario == "timer" || scenario == "timer-notepad" {
                            _ = try e.startTimer(task: e.planner.tasks[0].id, minutes: 45)
                            try e.pauseTimer()
                        }
                        if scenario == "timer-notepad" { e.planner.preferences.hiddenWorkspaceCards = [] }
                    }
                    let open = await openHomeTraced(delegate, label: scenario, full: scenario == "dense")
                    FocusTraceLog.append(open, output: output)
                    recordFocus(delegate: delegate, scenario: scenario, output: output)
                    require(
                        (open["settledFocusAt"] as? Double ?? -1) >= 0 && open["focusedAtEnd"] as? Bool == true
                            && open["lostAfterFocus"] as? Bool == false,
                        "\(scenario): capture editor acquires stable focus within 3 s")
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
                    if scenario == "completed" && !baseline {
                        await wakeAX(); await settle()
                        guard let captureBounds = controlFrame("Add a task", in: root) else {
                            require(false, "completed: capture bounds exist"); return
                        }
                        guard
                            let button = axNodes(root).first(where: {
                                attribute($0, "accessibilityLabel") as? String == "Completed 3"
                            })
                        else { require(false, "completed: filter remains reachable"); return }
                        let selector = NSSelectorFromString("accessibilityPerformPress")
                        guard button.responds(to: selector), let implementation = button.method(for: selector) else {
                            require(false, "completed: filter exposes native action"); return
                        }
                        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                        require(
                            unsafeBitCast(implementation, to: Press.self)(button, selector),
                            "completed: filter action succeeds")
                        await settle(); await wakeAX(); await settle()
                        let title = delegate.store.planner.tasks[0].title
                        require(
                            controlFrame("Reopen \(title)", in: root) != nil,
                            "completed: finished rows expose Reopen")
                        require(
                            controlFrame("Add a task", in: root) == captureBounds,
                            "completed: capture stays fixed while browsing finished tasks")
                    }
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
                if !baseline {
                    // Regression check for the explicit-open focus race: close, reseed and reopen the dense
                    // Home repeatedly, tracing a full 3 s each time. Assert only after every repeat is recorded.
                    var repeats: [[String: Any]] = []
                    for iteration in 1...20 {
                        // Odd repeats leave a long draft in the open editor first, as long-title does before dense.
                        if iteration % 2 == 1, let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                            editor.isFieldEditor
                        {
                            editor.insertText(
                                String(repeating: "A multi-line capture draft with more release notes. ", count: 12),
                                replacementRange: NSRange(location: NSNotFound, length: 0))
                            await settle()
                        }
                        delegate.model.close()
                        delegate.store.seedFixture { e in
                            e.planner.tasks = []
                            e.planner.focus = nil
                            e.planner.preferences.hiddenWorkspaceCards = ["notepad"]
                            _ = try e.addTasks(
                                (1...24).map { "Review item \($0) for the release checklist" }, on: .day(e.today))
                        }
                        let open = await openHomeTraced(delegate, label: "dense-repeat-\(iteration)", full: true)
                        FocusTraceLog.append(open, output: output)
                        repeats.append(open)
                    }
                    let summary = repeats.map { open -> [String: Any] in
                        open.filter {
                            [
                                "label", "firstFocusedAt", "focusedAt800ms", "settledFocusAt", "focusedAtEnd",
                                "lostAfterFocus",
                            ]
                            .contains($0.key)
                        }
                    }
                    try! JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(
                        to: output.appendingPathComponent("capture-focus-dense-repeats.json"))
                    for open in repeats {
                        let label = open["label"] as! String
                        require(
                            (open["settledFocusAt"] as? Double ?? -1) >= 0 && open["focusedAtEnd"] as? Bool == true
                                && open["lostAfterFocus"] as? Bool == false,
                            "\(label): capture editor is focused and stays focused")
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
                        delegate.store.seedFixture { e in
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
                        delegate.store.seedFixture { e in
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
                        delegate.store.seedFixture { $0.planner.tasks = [] }
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
