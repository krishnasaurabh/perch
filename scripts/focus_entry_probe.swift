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
@MainActor
func nodes(_ root: NSObject) -> [NSObject] {
    var seen = Set<ObjectIdentifier>()
    func walk(_ node: NSObject, _ depth: Int) -> [NSObject] {
        guard depth < 60, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
        return [node] + ((attr(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap { walk($0, depth + 1) }
    }
    return walk(root, 0)
}
@MainActor
func control(_ label: String, in root: NSView) -> NSObject? {
    nodes(root).first { attr($0, "accessibilityLabel") as? String == label }
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
func key(_ character: String, code: UInt16, in window: NSWindow) {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        let event = NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: character,
            charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
        NSApp.sendEvent(event)
    }
}

MainActor.assumeIsolated {
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
                    key("\t", code: 48, in: window); await Task.yield()
                    if let focus = control("Start focus", in: root),
                        (attr(focus, "accessibilityFocused") as? NSNumber)?.boolValue == true
                    {
                        key(" ", code: 49, in: window); await settle()
                        keyboardVerified = store.planner.focus?.state == .running
                        break
                    }
                }
                if store.planner.focus != nil { press("End focus session", in: root); await settle() }
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
            // Existing task focus: ask the real hosted row for its context menu, then activate its actual item.
            store.seedFixture { e in
                e.planner.tasks = []; e.planner.focus = nil
            }
            let linked = store.apply { try $0.addTasks(["Verify a single linked task"], on: .day(store.today)) }![0]
            store.updateTask(linked.id) { $0.minutes = 12 }
            let rowWindow = NSWindow(
                contentRect: CGRect(x: 50, y: 100, width: 420, height: 80), styleMask: [.titled], backing: .buffered,
                defer: false)
            rowWindow.isReleasedWhenClosed = false
            let rowRoot = NSHostingView(
                rootView: TaskRow(task: store.planner.tasks[0]).environmentObject(store).environmentObject(
                    delegate.model))
            rowWindow.contentView = rowRoot; rowWindow.makeKeyAndOrderFront(nil)
            await settle(); await wakeAX(); await settle()
            let contextEvent = NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: 120, y: 40), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rowWindow.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            var taskMenu: NSMenu?
            for view in views(rowRoot) {
                if let menu = view.menu(for: contextEvent), menu.items.contains(where: { $0.title == "Start focusing" })
                {
                    taskMenu = menu; break
                }
            }
            require(taskMenu != nil, "existing task context menu exposes Start focusing")
            let index = taskMenu!.items.firstIndex { $0.title == "Start focusing" }!
            require(taskMenu!.items[index].isEnabled, "existing task menu item enabled")
            taskMenu!.performActionForItem(at: index)
            await settle()
            require(
                store.planner.focus?.taskID == linked.id && store.planner.focus?.limit == 720,
                "task hover action retains exact ID and 12-minute estimate")
            require(
                store.planner.tasks.count == 1 && store.planner.tasks[0].id == linked.id
                    && store.planner.tasks[0].minutes == 12,
                "task action does not change task identity or estimate")
            snapshot(rowRoot, "task-hover", into: output)
            require(store.lastError == nil, "no store error during UI lifecycle")
            let report: [String: Any] = [
                "metrics": metrics,
                "keyboardActivation": keyboardVerified ? "verified-in-process-Tab-Space" : "unverified-on-this-runner",
                "activation": "real-own-process-AX-press-no-model-fallback",
                "taskActivation": "real-NSMenu-item-action-from-hosted-row",
                "screenshots": "own-window-cacheDisplay-not-compositor", "physicalNotch": "unverified",
                "voiceOverSpeech": "unverified",
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
