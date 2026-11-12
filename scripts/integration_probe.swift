import AppKit
@testable import PlannerCore
#if canImport(PerchApp)
    @testable import PerchApp
    import PerchUI
    import PerchMCP
    private typealias ProbeActivity = PerchApp.PresentedNotchActivity
#else
    private typealias ProbeActivity = PresentedNotchActivity
#endif
import EventKit
import SwiftUI
import Vision

@MainActor
func require(_ ok: @autoclosure () -> Bool, _ label: String) {
    guard ok() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
    print("PASS: \(label)")
}

@MainActor
func snapshot<V: View>(_ view: V, name: String, size: NSSize, output: URL) async throws {
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
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
    let display = NotchLayout.Screen(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944.5), safeAreaTop: 37.5,
        auxiliaryLeftWidth: 652, auxiliaryRightWidth: 652)
    for scale in [CGFloat(1), CGFloat(2)] {
        let g = NotchGeometry(screen: display, backingScaleFactor: scale)
        let camera = g.camera!
        let idle = g.idle(timer: nil, activity: false)
        require(
            camera.contains(idle) && idle.width < camera.width && idle.height < camera.height,
            "idle housing contains entire painted frame at \(scale)x")
        for side in [NotchTimerPlacement.left, .right] {
            let pill = g.pill(side: side)
            let bounds = g.idle(timer: side, activity: false)
            require(
                side == .left ? bounds.maxX == idle.maxX : bounds.minX == idle.minX,
                "\(side): opposite edge stays tucked inside housing at \(scale)x")
            require(
                pill.width == 76 && NotchGeometry.pillWidth == 76,
                "\(side): detached timer capsule is 76pt wide at \(scale)x")
            let gap = side == .left ? camera.minX - pill.maxX : pill.minX - camera.maxX
            require(
                gap == 6 && NotchGeometry.pillGap == 6 && bounds == idle.union(pill),
                "\(side): only chosen side grows with a 6pt housing gap at \(scale)x")
            require(
                abs(pill.height - camera.height * 0.72) <= 0.5 / scale,
                "\(side): capsule is 72 percent of housing height, pixel-snapped at \(scale)x")
            require(
                pill.minY - camera.minY >= 1 / scale && pill.maxY < camera.maxY,
                "\(side): capsule stays at least one pixel above housing bottom at \(scale)x")
            require(
                abs(pill.midY - idle.midY) < 1 / scale,
                "\(side): capsule is vertically centred within one device pixel at \(scale)x")
            for edge in [pill.minY, pill.maxY] {
                require(
                    abs(edge * scale - (edge * scale).rounded()) < 0.001,
                    "\(side): capsule edge lands on a device pixel at \(scale)x")
            }
            let gapPoint = NSPoint(
                x: side == .left ? camera.minX - gap / 2 : camera.maxX + gap / 2,
                y: pill.midY)
            require(
                !g.shapeContains(gapPoint, expanded: false, timer: side, activity: false),
                "\(side): detached gap is click-through at \(scale)x")
            for rect in [idle, pill] {
                require(
                    g.shapeContains(NSPoint(x: rect.midX, y: rect.midY), expanded: false, timer: side, activity: false),
                    "\(side): notch and capsule both accept hits at \(scale)x")
                require(g.window.contains(rect), "\(side): window contains notch and capsule at \(scale)x")
            }
            require(
                g.shape(expanded: true, timer: side, activity: false) == g.workspace,
                "\(side): expanded workspace geometry is unchanged at \(scale)x")
        }
        require(
            g.idle(timer: nil, activity: true).minY < camera.minY,
            "activity still extends below housing at \(scale)x")
    }
    let g = NotchGeometry(screen: display, backingScaleFactor: 2)
    let state = NotchScreenState(id: 99, geometry: g)
    model.screenID = state.id
    model.geometry = g
    store.updatePrefs { $0.notchOnMonitors = true }
    for name in ["idle", "left", "right", "hidden", "long", "running", "activity"] {
        _ = store.seedFixture { e in
            e.planner.tasks = []
            e.planner.focus = nil
            if name != "idle" && name != "activity" {
                let task = try e.addTasks(["Release timer check"], on: .day(e.today))[0]
                _ = try e.startTimer(task: task.id, minutes: name == "long" ? 120 : 5)
                if name != "running" { try e.pauseTimer() }
                e.planner.focus?.banked = 16
            }
            e.planner.preferences.notchTimerPlacement = name == "left" ? .left : name == "hidden" ? .hidden : .right
        }
        model.activity =
            name == "activity"
            ? ProbeActivity(kind: .message, title: "Release reminder", subtitle: "Activity remains below the housing")
            : nil
        let side = NotchModel.timerShowing(store)
        require(
            name == "idle" || name == "hidden" || name == "activity" ? side == nil : side != nil,
            "\(name): timer visibility follows focus and placement")
        try await snapshot(
            NotchRootView().environmentObject(store).environmentObject(model)
                .environmentObject(services).environmentObject(state).environment(
                    \.motionPolicyOverride, MotionPolicy(reduceMotion: true)),
            name: "notch-hug-\(name)", size: g.window.size, output: output)
    }
    model.activity = nil
    _ = store.seedFixture { e in
        e.planner.tasks = []; e.planner.focus = nil
    }
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
    require(
        store.planner.tasks.count == count && store.file.modificationDate == modified,
        "repeated display is read/write idempotent")
    _ = store.apply { try $0.endRepeat(of: root.id) }
    store.materializeRepeats(on: [next.adding(days: 3)])
    require(store.engine.tasks(on: .day(next.adding(days: 3))).isEmpty, "stop repeating prevents new occurrences")
    let reloaded = try store.file.load()
    require(reloaded.tasks.count == count, "repeat bookkeeping survived reload")

    _ = store.apply { try $0.addTasks(["Integration undo first"], on: .day($0.today)) }
    _ = store.apply { try $0.addTasks(["Integration undo second"], on: .day($0.today)) }
    store.undo()
    _ = store.performMutation(origin: .background) { try $0.tick() }
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
        try await snapshot(
            SettingsView().environmentObject(store).environmentObject(services).environment(\.colorScheme, scheme),
            name: "settings-\(dark ? "dark" : "light")", size: NSSize(width: 720, height: 600), output: output)
    }
    _ = store.seedFixture { e in
        e.planner.tasks.append(
            PlanTask(
                title: "Integration agent history", day: e.today.adding(days: -1), done: true, agentID: "claude-code"))
    }
    try await snapshot(
        HistoryList().environmentObject(store).padding(20).background(Color.white).environment(\.colorScheme, .light),
        name: "history-agent", size: NSSize(width: 800, height: 400), output: output)
    try await snapshot(
        ClipsPage().environmentObject(store).environmentObject(services).padding(20).background(Color.black)
            .environment(\.colorScheme, .dark),
        name: "clips-kept", size: NSSize(width: 820, height: 300), output: output)
    services.clips.sweep()
    try await snapshot(
        ClipsPage().environmentObject(store).environmentObject(services).padding(20).background(Color.black)
            .environment(\.colorScheme, .dark),
        name: "clips-undo", size: NSSize(width: 820, height: 300), output: output)
    try await checkPageMatrix(store: store, output: output)
    print("Integration probe passed")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    do { try await runProbe(); exit(0) } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
app.run()

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

// MARK: - Page matrix: Settings panes, Dashboard tabs, Welcome and Details states
//
// Every fixture below is synthetic: a temporary planner file with in-memory device
// preferences, a deliberately unreadable Reminders ledger, and a storage lock held by
// this probe. Nothing requests a permission, edits a login item or agent config, or
// reads the user's clips folder, Calendar or Reminders. Pages are driven by real key
// events dispatched through AppKit; results are read from rendered pixels (OCR) and
// from persisted planner state. No AX press or model call stands in for a key.

@MainActor
var matrixFailures: [String] = []

/// Records every red check, so one hosted run reports the whole matrix; the probe still exits 1.
@MainActor
func matrixRequire(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    guard ok else {
        matrixFailures.append(label)
        FileHandle.standardError.write(Data("FAIL: matrix: \(label)\n\(detail())\n".utf8))
        return
    }
    print("PASS: matrix: \(label)")
}

@MainActor
func matrixSettle(_ seconds: Double = 0.6) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

@MainActor
func matrixViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(matrixViews) }

/// A titled window that keeps its requested frame even when it is taller than the screen.
final class MatrixWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
func matrixWindow(_ content: NSView, size: NSSize) -> NSWindow {
    let window = MatrixWindow(
        contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = content
    window.setContentSize(size)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    return window
}

/// Recognized rendered text, lower-cased. Saved beside a PNG for the CI artifact.
@MainActor
func matrixText(_ view: NSView, name: String, output: URL) throws -> String {
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "" }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let directory = output.appendingPathComponent("matrix")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let png = bitmap.representation(using: .png, properties: [:]) {
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
    guard let image = bitmap.cgImage else { return "" }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    try Data(text.utf8).write(to: directory.appendingPathComponent(name + ".ocr.txt"))
    // Wrapped captions must still match as one phrase.
    return text.replacingOccurrences(of: "\n", with: " ").lowercased()
}

/// One key press (down and up) through the application's real event dispatch.
@MainActor
func matrixKey(
    _ window: NSWindow, _ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []
) async {
    // AppKit encodes Shift-Tab as back-tab in both character fields.
    let chars = code == 48 && modifiers.contains(.shift) ? "\u{19}" : characters
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        guard
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
        else { matrixRequire(false, "key event \(code) can be constructed"); return }
        NSApp.sendEvent(event)
    }
    await matrixSettle(0.4)
    print("matrix: key \(code) -> firstResponder \(String(describing: window.firstResponder.map { type(of: $0) }))")
}

/// Return or Escape delivered through the window's key-equivalent dispatch, as AppKit does for
/// default and cancel buttons.
@MainActor
func matrixKeyEquivalent(
    _ window: NSWindow, _ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []
) -> Bool {
    guard
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    else { return false }
    return window.performKeyEquivalent(with: event)
}

@MainActor
func matrixType(_ window: NSWindow, _ text: String) async {
    let codes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46,
    ]
    for character in text {
        guard let code = codes[character] else { matrixRequire(false, "typing fixture uses supported keys"); return }
        await matrixKey(window, code, String(character))
    }
}

/// Holds the planner's advisory lock from a separate descriptor, so every store mutation
/// fails exactly as it would while another Perch process is writing.
@MainActor
final class MatrixStorageLock {
    private let descriptor: Int32
    init(_ file: PlannerFile) {
        descriptor = open(file.lockURL.path, O_CREAT | O_RDWR, 0o600)
        matrixRequire(
            descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0, "synthetic storage lock is held")
    }
    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

final class MatrixCounter: @unchecked Sendable { var value = 0 }

@MainActor
struct MatrixFixture {
    let directory: URL
    let file: PlannerFile
    let store: PlannerStore
    let services: Services
    let project: TaskProject
    let past: PlanTask
    let draft: PlanTask

    init(name: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("perch-matrix-\(name)-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        let today = DayKey(Date())
        project = TaskProject(name: "Matrix garden")
        past = PlanTask(title: "Matrix history alpha", day: today.adding(days: -2), done: true, projectID: project.id)
        draft = PlanTask(title: "Matrix details draft", day: today)
        var planner = Planner()
        planner.preferences.welcomeCompleted = true
        planner.preferences.catchCopies = false
        planner.preferences.catchScreenshots = false
        planner.preferences.resetHour = 0
        planner.preferences.carryMode = .never
        planner.projects = [project]
        planner.tasks = [
            past,
            PlanTask(title: "Matrix history beta", day: today.adding(days: -3)),
            draft,
            PlanTask(title: "Matrix open project task", day: today, projectID: project.id),
            PlanTask(title: "Matrix future errand", day: today.adding(days: 2)),
        ]
        try file.save(planner)
        // Unreadable sync metadata: the Reminders service must report it, never repair it.
        try Data(#"{"version":99}"#.utf8).write(
            to: file.url.appendingPathExtension("reminders.json"))
        store = PlannerStore(file: file, watching: false)
        services = Services(store: store)
    }

    func close() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
func checkPageMatrix(store _: PlannerStore, output: URL) async throws {
    matrixRequire(Bundle.main.bundleIdentifier == nil, "probe is an unbundled process with no permission identity")
    // Never render a pane that could read the host's real Calendar or Reminders.
    matrixRequire(
        EKEventStore.authorizationStatus(for: .event) != .fullAccess
            && EKEventStore.authorizationStatus(for: .reminder) != .fullAccess,
        "probe host has no Calendar or Reminders read access")
    var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    arguments["AppleKeyboardUIMode"] = 3
    UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    let fixture = try MatrixFixture(name: "pages")
    defer { fixture.close() }
    await matrixSettle(1.0)
    try await checkSettingsMatrix(fixture, output: output)
    try await checkDashboardMatrix(fixture, output: output)
    try await checkWelcomeMatrix(fixture, output: output)
    try await checkDetailsMatrix(fixture, output: output)
    guard matrixFailures.isEmpty else {
        FileHandle.standardError.write(
            Data("FAIL: page matrix: \(matrixFailures.count) red: \(matrixFailures)\n".utf8))
        exit(1)
    }
    print("Page matrix passed")
}

@MainActor
func checkSettingsMatrix(_ fixture: MatrixFixture, output: URL) async throws {
    let host = NSHostingView(
        rootView: SettingsView().environmentObject(fixture.store).environmentObject(fixture.services)
            .environment(\.accessibilityEnabled, true))
    let window = matrixWindow(host, size: NSSize(width: 760, height: 1000))
    defer { window.close() }
    await matrixSettle(1.0)
    matrixRequire(window.isKeyWindow, "settings window owns the key window")
    print("matrix: full keyboard access=\(NSApp.isFullKeyboardAccessEnabled)")
    // The sidebar is the one native list with exactly one row per pane.
    let tables = matrixViews(host).compactMap { $0 as? NSTableView }
    print("matrix: settings tables \(tables.map { "\(type(of: $0)) rows=\($0.numberOfRows)" })")
    let sidebar = tables.first { $0.numberOfRows == SettingsView.Pane.allCases.count }
    matrixRequire(sidebar != nil, "settings exposes its native sidebar list")
    guard let sidebar else { return }
    matrixRequire(window.makeFirstResponder(sidebar), "settings sidebar accepts keyboard focus")
    let markers: [(SettingsView.Pane, String)] = [
        (.general, "open the notch on"), (.workspace, "reset to default"), (.focus, "default length"),
        (.agents, "use terminal"), (.system, "mirror tasks"),
    ]
    var previous: String?
    for (index, (pane, marker)) in markers.enumerated() {
        if index > 0 { await matrixKey(window, 125, "\u{f701}") }
        let text = try matrixText(host, name: "settings-\(pane.rawValue)", output: output)
        matrixRequire(
            sidebar.selectedRow == index, "settings Down arrow selects the \(pane.rawValue) pane",
            "selectedRow=\(sidebar.selectedRow)")
        matrixRequire(text.contains(marker), "settings \(pane.rawValue) pane renders its content", text)
        if let previous {
            matrixRequire(!text.contains(previous), "settings \(pane.rawValue) pane replaces the previous pane", text)
        }
        previous = marker
        try await checkSettingsFailure(pane, fixture: fixture, host: host, before: text, output: output)
    }
}

@MainActor
func checkSettingsFailure(
    _ pane: SettingsView.Pane, fixture: MatrixFixture, host: NSView, before: String, output: URL
) async throws {
    let name = "settings-\(pane.rawValue)-failure"
    switch pane {
    case .general:
        // The live hot key refused a chord. The row must say so and show what is kept.
        matrixRequire(!before.contains("give up"), "general pane starts without a shortcut failure", before)
        NotificationCenter.default.post(
            name: ShortcutStore.didFail, object: nil,
            userInfo: ["key": ShortcutKey(keyCode: 45, modifiers: [.command]), "restored": ShortcutKey.default])
        await matrixSettle()
        let text = try matrixText(host, name: name, output: output)
        matrixRequire(text.contains("give up"), "general pane reports a refused shortcut", text)
    case .workspace:
        let lock = MatrixStorageLock(fixture.file)
        fixture.store.updatePrefs { $0.hiddenWorkspaceCards = [] }
        await matrixSettle()
        let error = fixture.store.lastError?.message ?? ""
        let shown = fixture.store.prefs.hiddenWorkspaceCards
        lock.release()
        matrixRequire(error.contains("Another process"), "workspace pane edit reports busy storage", error)
        matrixRequire(shown == ["notepad"], "workspace pane does not show an unsaved card change", "\(shown)")
        matrixRequire(
            try fixture.file.load().preferences.hiddenWorkspaceCards == ["notepad"],
            "workspace pane failure leaves persisted cards unchanged")
        fixture.store.lastError = nil
    case .focus:
        matrixRequire(before.contains("25 min"), "focus pane shows the persisted default length", before)
        let lock = MatrixStorageLock(fixture.file)
        fixture.store.updatePrefs { $0.defaultFocusMinutes = 30 }
        await matrixSettle()
        let text = try matrixText(host, name: name, output: output)
        let error = fixture.store.lastError?.message ?? ""
        lock.release()
        matrixRequire(error.contains("Another process"), "focus pane edit reports busy storage", error)
        matrixRequire(
            text.contains("25 min") && !text.contains("30 min"), "focus pane keeps rendering the persisted length",
            text)
        matrixRequire(
            try fixture.file.load().preferences.defaultFocusMinutes == 25,
            "focus pane failure leaves the persisted length unchanged")
        fixture.store.lastError = nil
    case .agents:
        // The probe binary is not installed in Applications, so setup must refuse and say why.
        matrixRequire(!AppInfo.isInApplications, "agents fixture runs outside Applications")
        matrixRequire(before.contains("installed in applications"), "agents pane explains the setup refusal", before)
    case .system:
        let failure = fixture.services.remindersSync.lastError?.message ?? ""
        matrixRequire(
            failure.contains("not supported"), "reminders sync rejects unreadable synthetic metadata", failure)
        matrixRequire(before.contains("not supported"), "system pane renders the reminders sync failure", before)
        matrixRequire(
            try Data(contentsOf: fixture.file.url.appendingPathExtension("reminders.json"))
                == Data(#"{"version":99}"#.utf8),
            "system pane leaves unreadable reminders metadata untouched")
    }
}

@MainActor
func checkDashboardMatrix(_ fixture: MatrixFixture, output: URL) async throws {
    DashboardWindow.show(store: fixture.store, tab: .upcoming)
    guard let window = WindowHost.windows["dashboard"], let host = window.contentView else {
        matrixRequire(false, "dashboard window opens")
        return
    }
    defer { window.close() }
    await matrixSettle(1.0)
    matrixRequire(window.isKeyWindow, "dashboard window owns the key window")
    let picker = matrixViews(host).compactMap { $0 as? NSSegmentedControl }.first {
        $0.segmentCount == DashboardView.Tab.allCases.count
    }
    matrixRequire(picker != nil, "dashboard exposes its native tab control")
    guard let picker else { return }
    matrixRequire(window.makeFirstResponder(picker), "dashboard tab control accepts keyboard focus")
    let tabs: [(DashboardView.Tab, String)] = [
        (.upcoming, "matrix future errand"), (.history, "matrix history beta"), (.insights, "planned vs"),
        (.projects, "delete project"),
    ]
    for (index, (tab, marker)) in tabs.enumerated() {
        if index > 0 {
            await matrixKey(window, 124, "\u{f703}")
            await matrixKey(window, 49, " ")
        }
        let text = try matrixText(host, name: "dashboard-\(tab.rawValue)", output: output)
        matrixRequire(
            picker.selectedSegment == index, "dashboard keyboard selects the \(tab.rawValue) tab",
            "selectedSegment=\(picker.selectedSegment)")
        matrixRequire(text.contains(marker), "dashboard \(tab.rawValue) tab renders its content", text)
        if tab == .history {
            // Task lines: a typed search narrows the history list.
            await matrixKey(window, 48, "\t")
            let editor = window.firstResponder as? NSTextView
            let field = editor?.delegate as? NSTextField
            matrixRequire(
                field?.placeholderString == "Search history", "Tab moves from the tabs to the history search",
                "firstResponder=\(String(describing: window.firstResponder))")
            await matrixType(window, "alpha")
            await matrixSettle()
            let filtered = try matrixText(host, name: "dashboard-history-search", output: output)
            matrixRequire(
                filtered.contains("matrix history alpha") && !filtered.contains("matrix history beta"),
                "typed history search filters the task lines", filtered)
            await matrixKey(window, 48, "\t", .shift)
            matrixRequire(window.firstResponder === picker, "Shift-Tab returns focus to the dashboard tabs")
        }
    }
    // Project action: Tab to Delete project, Space deletes, Command-Z restores it.
    let before = fixture.store.planner
    await matrixKey(window, 48, "\t")
    await matrixKey(window, 49, " ")
    matrixRequire(fixture.store.planner.projects.isEmpty, "Space on Delete project deletes the project")
    let deleted = try fixture.file.load()
    matrixRequire(
        deleted.projects.isEmpty && deleted.tasks.allSatisfy { $0.projectID == nil },
        "project deletion persists and keeps its tasks")
    matrixRequire(deleted.tasks.count == before.tasks.count, "project deletion removes no task")
    matrixRequire(
        matrixKeyEquivalent(window, 6, "z", .command), "Command-Z reaches the dashboard key-equivalent dispatch")
    await matrixSettle()
    let restored = try fixture.file.load()
    matrixRequire(
        restored.projects.map(\.id) == [fixture.project.id]
            && restored.tasks.map(\.projectID) == before.tasks.map(\.projectID),
        "Command-Z restores the deleted project and its task links")
}

@MainActor
func checkWelcomeMatrix(_ fixture: MatrixFixture, output: URL) async throws {
    // History: Welcome reopened by a returning user whose planner already has history.
    let done = MatrixCounter()
    let tasksBefore = fixture.store.planner.tasks
    let host = NSHostingView(
        rootView: WelcomeView { done.value += 1 }.environmentObject(fixture.store)
            .environmentObject(fixture.services).environment(\.accessibilityEnabled, true))
    let window = matrixWindow(host, size: NSSize(width: 560, height: 900))
    await matrixSettle(1.5)
    let text = try matrixText(host, name: "welcome-returning", output: output)
    matrixRequire(text.contains("close at hand"), "welcome renders for a returning user", text)
    // Error: notification access cannot be granted to an unbundled process; it must say so.
    matrixRequire(
        text.contains("requires the installed perch app"), "welcome reports unavailable notification access", text)
    matrixRequire(matrixKeyEquivalent(window, 36, "\r"), "Return reaches the welcome default action")
    await matrixSettle()
    matrixRequire(done.value == 1, "Return opens the workspace exactly once", "done=\(done.value)")
    matrixRequire(fixture.store.planner.tasks == tasksBefore, "welcome leaves planner history unchanged")
    window.close()

    // Error: Welcome over planner data that cannot be read must still be operable and never rewrite it.
    let directory = fixture.directory.appendingPathComponent("corrupt")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("planner.json")
    let corrupt = Data(#"{"version":2,"tasks":5}"#.utf8)
    try corrupt.write(to: url)
    let store = PlannerStore(
        file: PlannerFile(url: url, preferences: MemoryPlannerPreferences()), watching: false)
    matrixRequire(store.lastError != nil, "unreadable planner data is reported to the app")
    let services = Services(store: store)
    let doneAfterError = MatrixCounter()
    let errorHost = NSHostingView(
        rootView: WelcomeView { doneAfterError.value += 1 }.environmentObject(store).environmentObject(services)
            .environment(\.accessibilityEnabled, true))
    let errorWindow = matrixWindow(errorHost, size: NSSize(width: 560, height: 900))
    defer { errorWindow.close() }
    await matrixSettle(1.5)
    let errorText = try matrixText(errorHost, name: "welcome-unreadable-data", output: output)
    matrixRequire(errorText.contains("close at hand"), "welcome renders over unreadable planner data", errorText)
    matrixRequire(matrixKeyEquivalent(errorWindow, 36, "\r"), "Return reaches welcome over unreadable data")
    await matrixSettle()
    matrixRequire(doneAfterError.value == 1, "welcome over unreadable data opens the workspace once")
    matrixRequire(try Data(contentsOf: url) == corrupt, "welcome never rewrites unreadable planner data")
}

@MainActor
func checkDetailsMatrix(_ fixture: MatrixFixture, output: URL) async throws {
    // History: a finished task from an earlier day is read-only.
    let historyHost = NSHostingView(
        rootView: TaskDetailsSheet(taskID: fixture.past.id).environmentObject(fixture.store)
            .environment(\.accessibilityEnabled, true))
    let historyWindow = matrixWindow(historyHost, size: NSSize(width: 460, height: 600))
    await matrixSettle(1.0)
    let history = try matrixText(historyHost, name: "details-history", output: output)
    matrixRequire(history.contains("read-only"), "details explain that history is read-only", history)
    // An editable task focuses its title on open; a historical one has no editable title at all.
    matrixRequire(
        !(historyWindow.firstResponder is NSTextView), "historical details offer no editable title",
        "firstResponder=\(String(describing: historyWindow.firstResponder))")
    historyWindow.close()

    // Error: the task was removed while its details were open.
    let missingHost = NSHostingView(
        rootView: TaskDetailsSheet(taskID: UUID()).environmentObject(fixture.store)
            .environment(\.accessibilityEnabled, true))
    let missingWindow = matrixWindow(missingHost, size: NSSize(width: 460, height: 400))
    await matrixSettle(1.0)
    let missing = try matrixText(missingHost, name: "details-removed", output: output)
    matrixRequire(
        missing.contains("task unavailable") && missing.contains("was removed"),
        "details explain a removed task", missing)
    missingWindow.close()

    // Error: saving a keyboard edit while storage is busy keeps the draft and says why.
    let draftHost = NSHostingView(
        rootView: TaskDetailsSheet(taskID: fixture.draft.id).environmentObject(fixture.store)
            .environment(\.accessibilityEnabled, true))
    let draftWindow = matrixWindow(draftHost, size: NSSize(width: 460, height: 600))
    defer { draftWindow.close() }
    await matrixSettle(1.0)
    let titleEditor = draftWindow.firstResponder as? NSTextView
    matrixRequire(
        titleEditor?.string == fixture.draft.title, "details focus the title field on open",
        "firstResponder=\(String(describing: draftWindow.firstResponder))")
    await matrixKey(draftWindow, 124, "\u{f703}")
    await matrixType(draftWindow, "x")
    matrixRequire(
        titleEditor?.string == fixture.draft.title + "x", "typed keys reach the details title",
        titleEditor?.string ?? "nil")
    let lock = MatrixStorageLock(fixture.file)
    let dispatched = matrixKeyEquivalent(draftWindow, 36, "\r")
    await matrixSettle()
    lock.release()
    // The inline error sits below the long form: scroll the real form to its end to read it.
    let form = matrixViews(draftHost).compactMap { $0 as? NSScrollView }.max {
        ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0)
    }
    if let form, let document = form.documentView {
        document.scroll(NSPoint(x: 0, y: document.isFlipped ? document.bounds.height : 0))
        form.reflectScrolledClipView(form.contentView)
    }
    await matrixSettle()
    let failed = try matrixText(draftHost, name: "details-save-busy", output: output)
    matrixRequire(dispatched, "Return reaches the details Save action")
    matrixRequire(failed.contains("another process"), "details show the storage failure after Save", failed)
    matrixRequire(
        try fixture.file.load().tasks.first { $0.id == fixture.draft.id }?.title == fixture.draft.title,
        "failed details save writes nothing")
    matrixRequire(titleEditor?.string == fixture.draft.title + "x", "failed details save keeps the draft")
}
