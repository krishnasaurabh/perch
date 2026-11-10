import AppKit
import PlannerCore
import SwiftUI

@MainActor
func require(_ ok: @autoclosure () -> Bool, _ label: String) {
    guard ok() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
    print("PASS: \(label)")
}

@MainActor
func snapshot<V: View>(_ view: V, name: String, size: NSSize, output: URL) async throws {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    window.orderFrontRegardless()
    try await Task.sleep(nanoseconds: 600_000_000)
    let content = window.contentView!
    let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
    content.cacheDisplay(in: content.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    window.orderOut(nil)
}

@MainActor
func checkClosedNotch(store: PlannerStore, model: NotchModel, services: Services, output: URL) async throws {
    let display = NotchLayout.Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944.5), safeAreaTop: 37.5,
        auxiliaryLeftWidth: 652, auxiliaryRightWidth: 652)
    for scale in [CGFloat(1), CGFloat(2)] {
        let g = NotchGeometry(screen: display, backingScaleFactor: scale)
        let camera = g.camera!
        let idle = g.idle(timer: nil, activity: false)
        require(camera.contains(idle) && idle.width < camera.width && idle.height < camera.height,
                "idle housing contains entire painted frame at \(scale)x")
        for side in [NotchTimerPlacement.left, .right] {
            let pill = g.idle(timer: side, activity: false)
            require(side == .left ? pill.maxX == camera.maxX : pill.minX == camera.minX,
                    "\(side): opposite edge stays at housing at \(scale)x")
            require(pill.width == camera.width + NotchGeometry.timerWing,
                    "\(side): only one timer wing grows at \(scale)x")
            require(abs((pill.minY - camera.minY) * scale - (scale == 1 ? 1.5 : 1)) < 0.001,
                    "\(side): bottom is at least one pixel above housing at \(scale)x")
            require(abs(pill.minY * scale - (pill.minY * scale).rounded()) < 0.001,
                    "\(side): bottom lands on a device pixel at \(scale)x")
        }
        require(g.idle(timer: nil, activity: true).minY < camera.minY,
                "activity still extends below housing at \(scale)x")
    }
    let g = NotchGeometry(screen: display, backingScaleFactor: 2)
    let state = NotchScreenState(id: 99, geometry: g)
    model.screenID = state.id
    model.geometry = g
    store.updatePrefs { $0.notchOnMonitors = true }
    for name in ["idle", "left", "right", "hidden", "long", "activity"] {
        _ = store.apply { e in
            e.planner.tasks = []
            e.planner.focus = nil
            if name != "idle" && name != "activity" {
                let task = try e.addTasks(["Release timer check"], on: .day(e.today))[0]
                _ = try e.startTimer(task: task.id.uuidString, minutes: name == "long" ? 120 : 5)
                try e.pauseTimer()
                e.planner.focus?.banked = 16
            }
            e.planner.preferences.notchTimerPlacement = name == "left" ? .left : name == "hidden" ? .hidden : .right
        }
        model.activity = name == "activity" ? NotchActivity(kind: .message, title: "Release reminder", subtitle: "Activity remains below the housing") : nil
        let side = NotchModel.timerShowing(store)
        require(name == "idle" || name == "hidden" || name == "activity" ? side == nil : side != nil,
                "\(name): timer visibility follows focus and placement")
        try await snapshot(NotchRootView().environmentObject(store).environmentObject(model)
            .environmentObject(services).environmentObject(state).environment(\.motionPolicyOverride, MotionPolicy(reduceMotion: true)),
            name: "notch-hug-\(name)", size: g.window.size, output: output)
    }
    model.activity = nil
    _ = store.apply { e in e.planner.tasks = []; e.planner.focus = nil }
}

@MainActor
func runProbe() async throws {
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["INTEGRATION_OUTPUT"]!)
    let store = PlannerStore()
    let model = NotchModel()
    let services = Services(store: store)
    services.attach(model: model)
    try await checkClosedNotch(store: store, model: model, services: services, output: output)
    let hour = Calendar.current.component(.hour, from: Date())
    store.updatePrefs { $0.resetHour = hour < 23 ? hour + 1 : 23 }
    require(store.today == store.engine.today, "store follows logical-day engine")
    require(store.capture.parse("Integration today").day == store.today, "capture uses store rollover hour")
    store.updatePrefs { $0.resetHour = 0 }
    let root = store.apply { try $0.addTasks(["Integration recurring check every 3 days"], on: .day($0.today)) }!.first!
    let next = store.today.adding(days: 3)
    store.materializeRepeats(on: [next])
    require(store.engine.tasks(on: .day(next)).count == 1, "shown day persists its repeat")
    let count = store.planner.tasks.count
    let modified = store.file.modificationDate
    store.materializeRepeats(on: [next])
    require(store.planner.tasks.count == count && store.file.modificationDate == modified, "repeated display is read/write idempotent")
    _ = store.apply { try $0.endRepeat(of: root.id) }
    store.materializeRepeats(on: [next.adding(days: 3)])
    require(store.engine.tasks(on: .day(next.adding(days: 3))).isEmpty, "stop repeating prevents new occurrences")
    let reloaded = try store.file.load()
    require(reloaded.tasks.count == count, "repeat bookkeeping survived reload")

    _ = store.apply { try $0.addTasks(["Integration undo first"], on: .day($0.today)) }
    _ = store.apply { try $0.addTasks(["Integration undo second"], on: .day($0.today)) }
    store.undo()
    _ = store.applyUntracked { $0.tick() }
    store.redo()
    require(store.planner.tasks.contains { $0.title == "Integration undo second" }, "untracked tick preserves Redo")

    services.clips.add(.text("Integration clip A"), source: "dropped")
    services.clips.add(.text("Integration clip B"), source: "dropped")
    let clipIDs = services.clips.clips.map(\.id)
    services.clips.letGo(clipIDs[0])
    require(services.clips.clips.count == 1 && services.clips.letGoBanner != nil, "let go exposes undo state")
    services.clips.undoLetGo()
    require(services.clips.clips.map(\.id) == clipIDs, "undo restores clip ordering")
    let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".txt")
    try Data("Integration kept file".utf8).write(to: temporary)
    services.clips.add(.file(temporary), source: "dropped")
    let kept = services.clips.clips.first!
    require(kept.origin == temporary && kept.content.fileURL != temporary, "temporary file gets an owned copy")
    try FileManager.default.removeItem(at: temporary)
    require(FileManager.default.fileExists(atPath: kept.content.fileURL!.path), "owned clip survives source removal")

    require(AgentName.short("claude-code") == "Claude", "agent label maps known client")
    require(AgentName.short("cursor-vscode") == "Cursor", "agent label maps Cursor")
    let suite = UserDefaults(suiteName: "PerchIntegrationProbe")!
    suite.removePersistentDomain(forName: "PerchIntegrationProbe")
    ShortcutStore.save(.default, defaults: suite, notify: false)
    require(ShortcutStore.load(defaults: suite) == .default, "shortcut round-trips in isolated defaults")
    suite.removePersistentDomain(forName: "PerchIntegrationProbe")

    for dark in [false, true] {
        let scheme: ColorScheme = dark ? .dark : .light
        try await snapshot(SettingsView().environmentObject(store).environmentObject(services).environment(\.colorScheme, scheme),
                           name: "settings-\(dark ? "dark" : "light")", size: NSSize(width: 720, height: 600), output: output)
    }
    _ = store.apply { e in
        e.planner.tasks.append(PlanTask(title: "Integration agent history", day: e.today.adding(days: -1), done: true, agentID: "claude-code"))
    }
    try await snapshot(HistoryList().environmentObject(store).padding(20).background(Color.white).environment(\.colorScheme, .light),
                       name: "history-agent", size: NSSize(width: 800, height: 400), output: output)
    try await snapshot(ClipsPage().environmentObject(store).environmentObject(services).padding(20).background(Color.black).environment(\.colorScheme, .dark),
                       name: "clips-kept", size: NSSize(width: 820, height: 300), output: output)
    services.clips.sweep()
    try await snapshot(ClipsPage().environmentObject(store).environmentObject(services).padding(20).background(Color.black).environment(\.colorScheme, .dark),
                       name: "clips-undo", size: NSSize(width: 820, height: 300), output: output)
    print("Integration probe passed")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    do { try await runProbe(); exit(0) }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
app.run()
