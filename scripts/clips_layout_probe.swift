// Temporary CI entry point. Renders the actual drop shelf; clipboard writes use a fake.
import AppKit
import EventKit
import SwiftUI
import Vision
import PlannerCore
#if canImport(PerchApp)
    @testable import PerchApp
    import PerchUI
    import PerchMCP
#endif

// This fixture owns the proposal. Content-derived window constraints must not
// silently replace it with the view's ideal height before a snapshot is taken.
@MainActor
func installClipsFixture(_ root: some View, in window: NSWindow, size: NSSize) -> NSView {
    let host = NSHostingView(rootView: root)
    host.sizingOptions = []
    window.contentView = host
    window.setContentSize(size)
    return host
}

@MainActor
func capture(_ view: NSView, size expectedSize: NSSize, to url: URL) throws {
    view.layoutSubtreeIfNeeded()
    let contentSize = view.window.map { $0.contentRect(forFrameRect: $0.frame).size } ?? .zero
    let geometry: [String: Any] = [
        "requestedSize": NSStringFromSize(expectedSize),
        "viewBounds": NSStringFromRect(view.bounds),
        "windowContentSize": NSStringFromSize(contentSize),
        "windowContentMinSize": NSStringFromSize(view.window?.contentMinSize ?? .zero),
        "windowContentMaxSize": NSStringFromSize(view.window?.contentMaxSize ?? .zero),
    ]
    try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
        .write(to: url.deletingPathExtension().appendingPathExtension("geometry.json"))
    guard view.bounds.size == expectedSize, contentSize == expectedSize else {
        throw NSError(
            domain: "ClipsLayout", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Native fixture size differs from the requested capture size"])
    }
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No bitmap") }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
    try png.write(to: url)
}

@MainActor
func settleClips() async { try? await Task.sleep(nanoseconds: 500_000_000) }

func requireClips(_ condition: Bool, _ message: String) throws {
    guard condition else {
        throw NSError(domain: "ClipsLayout", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@MainActor
func clipsAttribute(_ node: NSObject, _ name: String) -> Any? {
    let selector = NSSelectorFromString(name)
    return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
}

@MainActor
func clipsNodes(_ root: NSObject, includingNavigationOrder: Bool = false) -> [NSObject] {
    var seen = Set<ObjectIdentifier>()
    @MainActor func walk(_ node: NSObject) -> [NSObject] {
        guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
        let children = (clipsAttribute(node, "accessibilityChildren") as? [NSObject]) ?? []
        let contents = (clipsAttribute(node, "accessibilityContents") as? [NSObject]) ?? []
        let navigation =
            includingNavigationOrder
            ? (clipsAttribute(node, "accessibilityChildrenInNavigationOrder") as? [NSObject]) ?? [] : []
        let subviews = (node as? NSView)?.subviews ?? []
        return [node] + (children + contents + navigation + subviews).flatMap { walk($0) }
    }
    return walk(root)
}

@MainActor
func clipsNames(_ node: NSObject) -> [String] {
    let attributes = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
    let direct = attributes.compactMap { clipsAttribute(node, $0) as? String }
    // Native switches may associate a separate static-text label instead of
    // returning it from the control's own title/label getters.
    guard let label = clipsAttribute(node, "accessibilityTitleUIElement") as? NSObject else { return direct }
    return direct + attributes.compactMap { clipsAttribute(label, $0) as? String }
}

@MainActor
func writeClipsAccessibility(_ host: NSView, to url: URL) throws {
    let rows: [[String: Any]] = clipsNodes(host, includingNavigationOrder: true).map { node in
        var row: [String: Any] = ["class": NSStringFromClass(type(of: node)), "names": clipsNames(node)]
        for attribute in ["accessibilityRole", "accessibilityIdentifier"] {
            row[attribute] = clipsAttribute(node, attribute) as? String ?? ""
        }
        row["actions"] = clipsAttribute(node, "accessibilityActionNames") as? [String] ?? []
        if let cell = node as? NSCell {
            row["controlViewClass"] = cell.controlView.map { NSStringFromClass(type(of: $0)) } ?? ""
        }
        if let frame = try? clipsFrame(node, in: host) { row["frame"] = NSStringFromRect(frame) }
        if let value = clipsAttribute(node, "accessibilityValue") as? NSNumber { row["value"] = value }
        if let value = clipsAttribute(node, "accessibilityValue") as? String { row["value"] = value }
        return row
    }
    try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}

func matchesClipsControl(role: String?, names: [String], title: String) -> Bool {
    ["AXButton", "AXCheckBox", "AXSwitch", "AXPopUpButton", "AXMenuButton"].contains(role ?? "")
        && names.contains(title)
}

func clipsToggleState(role: String?, value: Any?) -> Bool? {
    if let label = value as? String {
        if label == "On" { return true }
        if label == "Off" { return false }
    }
    // SwiftUI can expose the Toggle's native checkbox state instead of the
    // styled button's string value. Reject mixed or missing checkbox states.
    if ["AXCheckBox", "AXSwitch"].contains(role ?? ""), let number = value as? NSNumber {
        if number.doubleValue == 0 { return false }
        if number.doubleValue == 1 { return true }
    }
    return nil
}

func checkClipsControlMatching() throws {
    try requireClips(clipsToggleState(role: "AXButton", value: "On") == true, "Missing On state")
    try requireClips(clipsToggleState(role: "AXButton", value: "Off") == false, "Missing Off state")
    try requireClips(clipsToggleState(role: "AXCheckBox", value: NSNumber(value: 1)) == true, "Missing checked state")
    try requireClips(
        clipsToggleState(role: "AXCheckBox", value: NSNumber(value: 0)) == false, "Missing unchecked state")
    try requireClips(clipsToggleState(role: "AXCheckBox", value: NSNumber(value: 2)) == nil, "Mixed state accepted")
    try requireClips(clipsToggleState(role: "AXButton", value: NSNumber(value: 1)) == nil, "Wrong role accepted")
    try requireClips(clipsToggleState(role: "AXCheckBox", value: nil) == nil, "Missing state accepted")
    for role in ["AXButton", "AXCheckBox", "AXSwitch", "AXPopUpButton", "AXMenuButton"] {
        try requireClips(
            matchesClipsControl(role: role, names: ["Add screenshots"], title: "Add screenshots"),
            "Control matching rejected \(role)")
    }
    let nonControlRoles: [String?] = [nil, "AXStaticText", "AXGroup"]
    for role in nonControlRoles {
        try requireClips(
            !matchesClipsControl(role: role, names: ["Add screenshots"], title: "Add screenshots"),
            "Control matching accepted a non-control")
    }
    for names in [[], ["Add screenshot"], ["Add screenshots elsewhere"]] {
        try requireClips(
            !matchesClipsControl(role: "AXSwitch", names: names, title: "Add screenshots"),
            "Control matching accepted a missing or partial label")
    }
}

@MainActor
func clipsControl(_ title: String, in host: NSView) throws -> NSObject {
    let matches = clipsNodes(host, includingNavigationOrder: true).filter { node in
        matchesClipsControl(
            role: clipsAttribute(node, "accessibilityRole") as? String, names: clipsNames(node), title: title)
    }
    try requireClips(matches.count == 1, "Expected one control named \(title), got \(matches.count)")
    return matches[0]
}

@MainActor
func clipsFrame(_ node: NSObject, in host: NSView) throws -> NSRect {
    try requireClips(node.responds(to: NSSelectorFromString("accessibilityFrame")), "Control has no frame")
    guard let value = node.value(forKey: "accessibilityFrame") as? NSValue, let window = host.window else {
        throw NSError(domain: "ClipsLayout", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing native frame"])
    }
    return host.convert(window.convertFromScreen(value.rectValue), from: nil)
}

@MainActor
func pressClips(_ title: String, in host: NSView) throws {
    let node = try clipsControl(title, in: host)
    let enabledSelector = NSSelectorFromString("isAccessibilityEnabled")
    guard node.responds(to: enabledSelector), let enabledMethod = node.method(for: enabledSelector) else {
        throw NSError(
            domain: "ClipsLayout", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing enabled state: \(title)"])
    }
    typealias Enabled = @convention(c) (AnyObject, Selector) -> Bool
    try requireClips(
        unsafeBitCast(enabledMethod, to: Enabled.self)(node, enabledSelector), "Disabled control: \(title)")
    let selector = NSSelectorFromString("accessibilityPerformPress")
    guard node.responds(to: selector), let implementation = node.method(for: selector) else {
        throw NSError(domain: "ClipsLayout", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot press \(title)"])
    }
    typealias Press = @convention(c) (AnyObject, Selector) -> Bool
    try requireClips(unsafeBitCast(implementation, to: Press.self)(node, selector), "Press rejected: \(title)")
}

#if CLIPS_PREVIEW_REGRESSION
    // MARK: Week and Clips keyboard actions (real key events, nested Escape, focus return)
    //
    // Every action below is a real NSEvent: Tab, Space, arrows, Return and Escape are dispatched
    // through NSApp.sendEvent, or posted into the native menu tracking loop. No accessibility press
    // or model write ever stands in for a key. Each run names at most one assertion to break on the
    // probe side (withhold the key, misroute focus, mutate the fixture); the parent requires that
    // exactly that assertion goes red, so every new assertion is shown able to fail on every run.

    let clipsKeyboardFlag = "--clips-keyboard"

    struct ClipsKeyboardFailure: Error, CustomStringConvertible {
        let assertion: String
        let detail: String
        var description: String { "\(assertion): \(detail)" }
    }

    @MainActor
    final class ClipsKeyboardRun {
        let broken: String?
        let evidenceDirectory: URL
        private(set) var passed: [String] = []
        var trace: [String] = []
        init(broken: String?, evidenceDirectory: URL) {
            self.broken = broken
            self.evidenceDirectory = evidenceDirectory
        }

        func record(_ message: String) {
            trace.append(message)
            FileHandle.standardError.write(Data("Clips keyboard: \(message)\n".utf8))
        }

        func breaks(_ assertion: String) -> Bool { broken == assertion }

        func require(_ condition: Bool, _ assertion: String, _ detail: @autoclosure () -> String = "") throws {
            guard condition else { throw ClipsKeyboardFailure(assertion: assertion, detail: detail()) }
            passed.append(assertion)
        }
    }

    /// The ordered assertion set; the parent breaks each one in turn.
    let clipsKeyboardAssertions = [
        "week: Tab reaches the task-line actions menu",
        "week: Space opens the native task-line menu",
        "week: Escape closes the task-line menu",
        "week: focus returns to the task-line menu after Escape",
        "week: cancelling the task-line menu never mutates the task",
        "week: arrow keys and Return choose Details and attach the sheet",
        "week: nested Escape dismisses the details sheet",
        "week: focus returns to the task-line menu after the sheet closes",
        "week: cancelling the details sheet never mutates the task",
        "clips: Tab reaches the clip copy control",
        "clips: Space copies the clip once into the fake pasteboard",
        "clips: focus stays on the copy control after Space",
        "clips: Tab reaches Clear on the shelf",
        "clips: Space clears the shelf as one batch",
        "clips: Tab reaches shelf Undo",
        "clips: Space Undo restores persisted shelf identities and order",
        "clips: Tab returns to the shelf item",
        "clips: Delete removes only the focused shelf item",
        "clips: Return opens the kept file without changing its original",
    ]

    @MainActor
    private final class ClipsKeyboardPasteboard: PasteboardAccess {
        var writes: [PasteboardValue] = []
        var changeCount: Int { writes.count }
        let declaredTypes: [String] = []
        let fileURLs: [URL] = []
        let imageData: Data? = nil
        let plainText: String? = nil
        func replace(with value: PasteboardValue) { writes.append(value) }
    }

    @MainActor
    private final class ClipsKeyboardDestinations {
        let before = NSTextField(string: "Before keyboard fixture")
    }

    private struct ClipsKeyboardDestination: NSViewRepresentable {
        let field: NSTextField
        func makeNSView(context: Context) -> NSTextField { field }
        func updateNSView(_ view: NSTextField, context: Context) {}
    }

    private struct ClipsKeyboardHarness<Content: View>: View {
        let destinations: ClipsKeyboardDestinations
        @ViewBuilder var content: Content
        var body: some View {
            VStack(spacing: 6) {
                ClipsKeyboardDestination(field: destinations.before).frame(height: 22)
                content
            }
            .padding(8).background(Color.black)
        }
    }

    @MainActor
    func clipsKeyEvent(
        _ code: UInt16, _ characters: String, type: NSEvent.EventType, windowNumber: Int
    ) throws -> NSEvent {
        guard
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code)
        else { throw ClipsKeyboardFailure(assertion: "key event construction", detail: "code \(code)") }
        return event
    }

    @MainActor
    func clipsKeySettle() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
        NSApp.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
    }

    /// A real key press: keyDown and keyUp dispatched through the application event path.
    @MainActor
    func clipsKey(_ window: NSWindow, _ code: UInt16, _ characters: String) async throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            NSApp.sendEvent(try clipsKeyEvent(code, characters, type: type, windowNumber: window.windowNumber))
        }
        await clipsKeySettle()
    }

    @MainActor
    func clipsBool(_ node: NSObject, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard node.responds(to: selector), let implementation = node.method(for: selector) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(implementation, to: Getter.self)(node, selector)
    }

    /// A focused native descendant need not also appear in accessibilityChildren.
    /// Include navigation-order children and the public focused-element getter, but
    /// still require the target's own typed isAccessibilityFocused result below.
    @MainActor
    func clipsKeyboardNodes(_ window: NSWindow) -> [NSObject] {
        guard let content = window.contentView else { return [] }
        var nodes = clipsNodes(content, includingNavigationOrder: true)
        let owners: [NSObject] = [NSApp, window, content, window.firstResponder].compactMap { $0 }
        for owner in owners {
            if let focused = clipsAttribute(owner, "accessibilityFocusedUIElement") as? NSObject {
                nodes.append(focused)
            }
        }
        var seen = Set<ObjectIdentifier>()
        return nodes.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    @MainActor
    func clipsFocusedNames(_ window: NSWindow) -> [String] {
        return clipsKeyboardNodes(window).filter { clipsBool($0, "isAccessibilityFocused") }.map { node in
            let identifier = clipsAttribute(node, "accessibilityIdentifier") as? String ?? ""
            return ([identifier] + clipsNames(node)).filter { !$0.isEmpty }.joined(separator: "|")
        }
    }

    /// Native focus on a control carrying this identifier or accessibility label.
    @MainActor
    func clipsIsFocused(_ window: NSWindow, _ name: String) -> Bool {
        guard window.isKeyWindow else { return false }
        return clipsKeyboardNodes(window).contains { node in
            (clipsAttribute(node, "accessibilityIdentifier") as? String == name || clipsNames(node).contains(name))
                && clipsBool(node, "isAccessibilityFocused")
        }
    }

    @MainActor
    func writeClipsKeyboardState(_ window: NSWindow, target: String, to url: URL) throws {
        let rows: [[String: Any]] = clipsKeyboardNodes(window).map { node in
            var row: [String: Any] = [
                "class": NSStringFromClass(type(of: node)), "names": clipsNames(node),
                "identifier": clipsAttribute(node, "accessibilityIdentifier") as? String ?? "",
                "role": clipsAttribute(node, "accessibilityRole") as? String ?? "",
                "hasFocusGetter": node.responds(to: NSSelectorFromString("isAccessibilityFocused")),
                "focused": clipsBool(node, "isAccessibilityFocused"),
                "enabled": clipsBool(node, "isAccessibilityEnabled"),
            ]
            if let view = node as? NSView {
                row["acceptsFirstResponder"] = view.acceptsFirstResponder
                row["hidden"] = view.isHiddenOrHasHiddenAncestor
                row["visibleRect"] = NSStringFromRect(view.visibleRect)
            }
            if let host = window.contentView, let frame = try? clipsFrame(node, in: host) {
                row["frame"] = NSStringFromRect(frame)
            }
            return row
        }
        let evidence: [String: Any] = [
            "target": target, "keyWindow": window.isKeyWindow, "visible": window.isVisible,
            "firstResponderClass": window.firstResponder.map { NSStringFromClass(type(of: $0)) } ?? "",
            "firstResponderNames": window.firstResponder.map { clipsNames($0) } ?? [],
            "focusedNames": clipsFocusedNames(window), "nodes": rows,
        ]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    @MainActor
    func clipsTabUntil(
        _ window: NSWindow, _ name: String, run: ClipsKeyboardRun, assertion: String, limit: Int = 30
    ) async throws {
        let prefix = run.evidenceDirectory.appendingPathComponent("tab-\(run.passed.count)")
        try writeClipsKeyboardState(window, target: name, to: prefix.appendingPathExtension("before.json"))
        if let host = window.contentView {
            try capture(host, size: host.bounds.size, to: prefix.appendingPathExtension("before.png"))
        }
        var traversal: [String] = []
        for _ in 0..<limit {
            // The broken variant withholds the Tab key itself, so focus can never arrive.
            if !run.breaks(assertion) { try await clipsKey(window, 48, "\t") } else { await clipsKeySettle() }
            traversal.append(clipsFocusedNames(window).joined(separator: ","))
            run.record(
                "\(assertion) step \(traversal.count): key=\(window.isKeyWindow) "
                    + "responder=\(window.firstResponder.map { NSStringFromClass(type(of: $0)) } ?? "none") "
                    + "focus=\(traversal.last ?? "")")
            try writeClipsKeyboardState(
                window, target: name, to: prefix.appendingPathExtension("step-\(traversal.count).json"))
            if clipsIsFocused(window, name) { break }
        }
        run.record("\(assertion) traversal: \(traversal)")
        try writeClipsKeyboardState(window, target: name, to: prefix.appendingPathExtension("after.json"))
        try run.require(clipsIsFocused(window, name), assertion, "traversal \(traversal)")
    }

    /// Observes one native menu tracking session and drives it only with posted key events.
    @MainActor
    final class ClipsKeyMenuSession: NSObject {
        enum Plan {
            case escape
            case choose(String)
            case nothing
        }
        let plan: Plan
        private(set) var menu: NSMenu?
        private(set) var items: [String] = []
        private(set) var endedBeforeDeadline = false
        private(set) var cancelledAtDeadline = false
        private var posted = false
        private var steps = 0
        private var timer: Timer?
        private let windowNumber: Int
        private let deadline = ProcessInfo.processInfo.systemUptime + 3

        init(plan: Plan, windowNumber: Int) {
            self.plan = plan
            self.windowNumber = windowNumber
        }

        func start() {
            NotificationCenter.default.addObserver(
                self, selector: #selector(began(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(ended(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
            let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            self.timer = timer
            RunLoop.main.add(timer, forMode: .eventTracking)
            RunLoop.main.add(timer, forMode: .default)
        }

        func stop() {
            timer?.invalidate()
            timer = nil
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func began(_ notification: Notification) {
            guard menu == nil, let tracked = notification.object as? NSMenu, !tracked.items.isEmpty else { return }
            menu = tracked
            items = tracked.items.map(\.title)
        }

        @objc private func ended(_ notification: Notification) {
            guard let tracked = notification.object as? NSMenu, tracked === menu, !cancelledAtDeadline else { return }
            endedBeforeDeadline = true
        }

        private func post(_ code: UInt16, _ characters: String) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = try? clipsKeyEvent(code, characters, type: type, windowNumber: windowNumber) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }

        @objc private func tick() {
            if let menu, !posted {
                switch plan {
                case .escape:
                    posted = true
                    post(53, "\u{1b}")
                case .choose(let title):
                    // One real Down Arrow per tick until the native highlight is on the target, then Return.
                    if menu.highlightedItem?.title == title {
                        posted = true
                        post(36, "\r")
                    } else if steps < 12 {
                        steps += 1
                        post(125, "\u{f701}")
                    }
                case .nothing:
                    posted = true
                }
            }
            if endedBeforeDeadline || ProcessInfo.processInfo.systemUptime >= deadline {
                // A session nobody closed by key is cancelled here and reported as such, never as a pass.
                if !endedBeforeDeadline, let menu {
                    cancelledAtDeadline = true
                    menu.cancelTracking()
                }
                timer?.invalidate()
                timer = nil
            }
        }
    }

    /// Press Space on the focused control (or withhold it) and drive the menu with posted keys.
    @MainActor
    func clipsOpenMenuByKey(
        _ window: NSWindow, plan: ClipsKeyMenuSession.Plan, withholdSpace: Bool
    ) async throws -> ClipsKeyMenuSession {
        let session = ClipsKeyMenuSession(plan: plan, windowNumber: window.windowNumber)
        session.start()
        defer { session.stop() }
        if !withholdSpace {
            // The keyDown enters the native tracking loop and returns once the menu has closed.
            try await clipsKey(window, 49, " ")
        }
        let limit = ProcessInfo.processInfo.systemUptime + 3.5
        while !(session.endedBeforeDeadline || session.cancelledAtDeadline)
            && ProcessInfo.processInfo.systemUptime < limit
        {
            await clipsKeySettle()
        }
        await clipsKeySettle()
        return session
    }

    @MainActor
    func clipsKeyboardWindow(_ title: String, _ view: some View, size: NSSize) -> (NSWindow, NSView) {
        // Activate accessibility at the hosting root, including the native starting
        // field and presented content, rather than just the inner page subtree.
        let host = NSHostingView(rootView: view.environment(\.accessibilityEnabled, true))
        host.sizingOptions = []
        host.safeAreaRegions = []
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    @MainActor
    func clipsKeyboardWeek(_ run: ClipsKeyboardRun, directory: URL) async throws {
        let file = PlannerFile(url: directory.appendingPathComponent("week-keyboard-\(UUID()).json"))
        let store = PlannerStore(file: file, watching: false)
        store.updatePrefs {
            $0.welcomeCompleted = true
            $0.catchCopies = false
            $0.catchScreenshots = false
            $0.remindersSync = false
            $0.resetHour = 0
        }
        guard let task = store.addTasks(["Keyboard week task"], on: .day(store.today), literal: true)?.first else {
            throw ClipsKeyboardFailure(assertion: "week fixture", detail: "could not seed today's task")
        }
        let services = Services(store: store)
        let model = NotchModel()
        model.page = .week
        let destinations = ClipsKeyboardDestinations()
        let (window, _) = clipsKeyboardWindow(
            "Keyboard Week",
            ClipsKeyboardHarness(destinations: destinations) {
                WorkspaceView(notchHeight: 32)
                    .environmentObject(store).environmentObject(services).environmentObject(model)
                    .environment(\.accessibilityEnabled, true).environment(\.colorScheme, .dark)
                    .frame(width: 900, height: 440)
            }, size: NSSize(width: 916, height: 486))
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close()
        }
        await settleClips()
        try run.require(window.makeFirstResponder(destinations.before), "week fixture", "no starting field")
        try run.require(
            window.isKeyWindow && destinations.before.currentEditor() === window.firstResponder,
            "week fixture", "starting field must own the key window's native editor")
        let menuID = "week-menu-\(task.id)"
        func fingerprint() -> [String] {
            store.planner.tasks.map { "\($0.id) \($0.title) \($0.done) \($0.day as Any)" }
        }
        let before = fingerprint()

        try await clipsTabUntil(window, menuID, run: run, assertion: clipsKeyboardAssertions[0])
        let cancel = try await clipsOpenMenuByKey(
            window, plan: run.breaks(clipsKeyboardAssertions[2]) ? .nothing : .escape,
            withholdSpace: run.breaks(clipsKeyboardAssertions[1]))
        run.record("week menu items: \(cancel.items)")
        try run.require(
            cancel.menu != nil && cancel.items.contains(AppL10n.text("Details…")), clipsKeyboardAssertions[1],
            "items \(cancel.items)")
        try run.require(
            cancel.endedBeforeDeadline && !cancel.cancelledAtDeadline, clipsKeyboardAssertions[2],
            "menu stayed open until the probe deadline")
        if run.breaks(clipsKeyboardAssertions[3]) { _ = window.makeFirstResponder(destinations.before) }
        await clipsKeySettle()
        try run.require(
            clipsIsFocused(window, menuID), clipsKeyboardAssertions[3], "focused \(clipsFocusedNames(window))")
        if run.breaks(clipsKeyboardAssertions[4]) { _ = store.send(.complete(task.id)) }
        try run.require(fingerprint() == before, clipsKeyboardAssertions[4], "tasks \(fingerprint())")

        // Nested Escape: a keyboard-chosen menu item opens the details sheet inside the page.
        let details = try await clipsOpenMenuByKey(
            window, plan: run.breaks(clipsKeyboardAssertions[5]) ? .escape : .choose(AppL10n.text("Details…")),
            withholdSpace: false)
        for _ in 0..<12 where window.attachedSheet == nil { await clipsKeySettle() }
        try run.require(
            details.endedBeforeDeadline && window.attachedSheet != nil && model.detailsTaskID == task.id,
            clipsKeyboardAssertions[5], "items \(details.items) sheet \(window.attachedSheet != nil)")
        let sheet = window.attachedSheet!
        if !run.breaks(clipsKeyboardAssertions[6]) { try await clipsKey(sheet, 53, "\u{1b}") }
        for _ in 0..<12 where window.attachedSheet != nil { await clipsKeySettle() }
        try run.require(
            window.attachedSheet == nil && model.detailsTaskID == nil, clipsKeyboardAssertions[6],
            "sheet still attached")
        if run.breaks(clipsKeyboardAssertions[7]) { _ = window.makeFirstResponder(destinations.before) }
        await clipsKeySettle()
        try run.require(
            clipsIsFocused(window, menuID), clipsKeyboardAssertions[7], "focused \(clipsFocusedNames(window))")
        if run.breaks(clipsKeyboardAssertions[8]) { _ = store.send(.complete(task.id)) }
        let persisted = try file.load().tasks.map { "\($0.id) \($0.done)" }
        try run.require(
            fingerprint() == before && persisted == ["\(task.id) false"], clipsKeyboardAssertions[8],
            "tasks \(fingerprint()) persisted \(persisted)")
    }

    @MainActor
    func clipsKeyboardClips(_ run: ClipsKeyboardRun, directory: URL) async throws {
        let root = directory.appendingPathComponent("shelf-keyboard-\(UUID())")
        let store = PlannerStore(file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
        let pasteboard = ClipsKeyboardPasteboard()
        var opened: [URL] = []
        let clips = ClipsService(
            store: store, pasteboard: pasteboard, monitoring: false,
            clipOpener: { url, completion in
                opened.append(url); completion(nil)
            })
        let source = root.appendingPathComponent("Keyboard original.txt")
        try Data("Original file bytes".utf8).write(to: source)
        clips.add(.file(source), source: "dropped")
        clips.add(.text("Keyboard clip one"), source: "dropped")
        guard clips.clips.count == 2, let first = clips.clips.first(where: { $0.title == "Keyboard clip one" }),
            let file = clips.clips.first(where: { $0.title == "Keyboard original.txt" })
        else { throw ClipsKeyboardFailure(assertion: "clips fixture", detail: "expected a file and text") }
        let destinations = ClipsKeyboardDestinations()
        let (window, _) = clipsKeyboardWindow(
            "Keyboard Drop Shelf",
            ClipsKeyboardHarness(destinations: destinations) {
                DropShelf(clips: clips).environmentObject(store)
                    .environment(\.accessibilityEnabled, true).environment(\.colorScheme, .light)
                    .frame(width: 640).padding(24).background(Color.black)
            }, size: NSSize(width: 704, height: 360))
        defer { window.close() }
        await settleClips()
        try run.require(window.makeFirstResponder(destinations.before), "clips fixture", "no starting field")
        try run.require(
            window.isKeyWindow && destinations.before.currentEditor() === window.firstResponder,
            "clips fixture", "starting field must own the native editor")
        let before = clips.clips.map(\.id)
        let copyLabel = AppL10n.format("Copy %@", first.title)
        try await clipsTabUntil(window, copyLabel, run: run, assertion: clipsKeyboardAssertions[9])
        if !run.breaks(clipsKeyboardAssertions[10]) { try await clipsKey(window, 49, " ") }
        try run.require(
            pasteboard.writes.count == 1
                && {
                    if case .text(let text) = pasteboard.writes[0] { return text == "Keyboard clip one" }; return false
                }(),
            clipsKeyboardAssertions[10], "Space must copy the exact item once")
        if run.breaks(clipsKeyboardAssertions[11]) { _ = window.makeFirstResponder(destinations.before) }
        try run.require(clipsIsFocused(window, copyLabel), clipsKeyboardAssertions[11], "copy focus lost")
        try await clipsTabUntil(window, "shelf.clear", run: run, assertion: clipsKeyboardAssertions[12])
        if !run.breaks(clipsKeyboardAssertions[13]) { try await clipsKey(window, 49, " ") }
        try run.require(
            clips.clips.isEmpty && clips.letGoBanner?.count == 2,
            clipsKeyboardAssertions[13], "Clear must remove both items as one batch")
        try await clipsTabUntil(window, "shelf.undo", run: run, assertion: clipsKeyboardAssertions[14])
        if !run.breaks(clipsKeyboardAssertions[15]) { try await clipsKey(window, 49, " ") }
        let saved = try ClipShelfFile(vault: clips.vault).load().map(\.id)
        try run.require(
            clips.clips.map(\.id) == before && saved == before,
            clipsKeyboardAssertions[15], "Undo must restore stable persisted order")
        try await clipsTabUntil(window, copyLabel, run: run, assertion: clipsKeyboardAssertions[16])
        if !run.breaks(clipsKeyboardAssertions[17]) { try await clipsKey(window, 51, "\u{8}") }
        try run.require(
            clips.clips.map(\.id) == [file.id] && clips.letGoBanner?.count == 1,
            clipsKeyboardAssertions[17], "Delete must remove only the focused item")
        try await clipsTabUntil(
            window, AppL10n.format("Copy %@", file.title),
            run: ClipsKeyboardRun(broken: nil, evidenceDirectory: run.evidenceDirectory), assertion: "file focus")
        if !run.breaks(clipsKeyboardAssertions[18]) { try await clipsKey(window, 36, "\r") }
        try run.require(
            opened == [clips.clipURL(file)!] && (try Data(contentsOf: source)) == Data("Original file bytes".utf8),
            clipsKeyboardAssertions[18], "Return must open the kept file without editing its source")
    }

    /// Child entry point: launched with -AppleKeyboardUIMode 3 so Tab reaches every control.
    @MainActor
    func runClipsKeyboardChild(out: URL) async -> Never {
        let budget = ProcessInfo.processInfo.environment["CLIPS_KEYBOARD_NEGATIVES"] == "1" ? 600.0 : 60.0
        DispatchQueue.global().asyncAfter(deadline: .now() + budget) {
            FileHandle.standardError.write(Data("Clips keyboard: watchdog expired\n".utf8))
            exit(3)
        }
        var results: [[String: Any]] = []
        var failures = 0
        do {
            try requireClips(Bundle.main.bundleIdentifier == nil, "Keyboard probe must remain unbundled")
            let calendar = EKEventStore.authorizationStatus(for: .event)
            try requireClips(
                calendar != .fullAccess && calendar != .writeOnly, "Keyboard probe refuses a calendar-enabled host")
            // Same mechanism as the green workspace navigation probe: the argument-domain override,
            // made explicit in the volatile domain. NSApp.isFullKeyboardAccessEnabled reads only the
            // global preference, which this probe must never write, so it is not the gate here.
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments["AppleKeyboardUIMode"] = 3
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            try requireClips(
                UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") == 3,
                "Keyboard probe needs full keyboard access in the argument domain")
        } catch {
            fputs("Clips keyboard precondition failed: \(error)\n", stderr)
            exit(1)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clips-keyboard-\(UUID())")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PERCH_DATA", directory.appendingPathComponent("unused-planner.json").path, 1)
        // nil is the unbroken tree. Negative-control mode (scratch runs only) then breaks each
        // assertion once, on the probe side, and requires exactly that assertion to go red.
        let negatives = ProcessInfo.processInfo.environment["CLIPS_KEYBOARD_NEGATIVES"] == "1"
        let brokenRuns: [String?] = [nil] + (negatives ? clipsKeyboardAssertions.map { Optional($0) } : [])
        for (index, broken) in brokenRuns.enumerated() {
            let run = ClipsKeyboardRun(
                broken: broken, evidenceDirectory: out.appendingPathComponent("keyboard-\(index)"))
            var red: ClipsKeyboardFailure?
            let surface = broken.map { $0.hasPrefix("week") ? "week" : "clips" }
            do {
                try FileManager.default.createDirectory(at: run.evidenceDirectory, withIntermediateDirectories: true)
                if surface != "clips" { try await clipsKeyboardWeek(run, directory: directory) }
                if surface != "week" { try await clipsKeyboardClips(run, directory: directory) }
            } catch let failure as ClipsKeyboardFailure {
                red = failure
            } catch {
                red = ClipsKeyboardFailure(assertion: "unexpected", detail: "\(error)")
            }
            let ok = broken == nil ? red == nil : red?.assertion == broken
            if !ok { failures += 1 }
            let label = broken.map { "negative control [\($0)]" } ?? "unbroken tree"
            print("\(ok ? "PASS" : "FAIL"): clips keyboard \(label): red=\(red?.description ?? "none")")
            results.append([
                "broken": broken ?? "", "red": red?.assertion ?? "", "detail": red?.detail ?? "",
                "passed": run.passed, "trace": run.trace, "ok": ok,
            ])
        }
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: out.appendingPathComponent("clips-keyboard.json"))
        }
        print("Clips keyboard: \(clipsKeyboardAssertions.count) assertions, \(failures) failed runs")
        try? FileManager.default.removeItem(at: directory)
        exit(failures == 0 ? 0 : 1)
    }

    /// Run the keyboard matrix in a child with full keyboard access as an argument-domain override.
    @MainActor
    func checkClipsKeyboard() throws {
        guard let executable = Bundle.main.executableURL else {
            throw ClipsKeyboardFailure(assertion: "spawn", detail: "no executable")
        }
        // Hand activation to the child so its fixture windows can become key.
        NSApp.windows.forEach { $0.orderOut(nil) }
        NSApp.deactivate()
        let child = Process()
        child.executableURL = executable
        child.arguments = ["-AppleKeyboardUIMode", "3", clipsKeyboardFlag]
        try child.run()
        child.waitUntilExit()
        try requireClips(
            child.terminationReason == .exit && child.terminationStatus == 0,
            "Week/Clips keyboard matrix failed: status \(child.terminationStatus) "
                + "reason \(child.terminationReason.rawValue)")
    }
#endif

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLIPS_OUTPUT"]!)
    #if CLIPS_PREVIEW_REGRESSION
        if CommandLine.arguments.contains(clipsKeyboardFlag) {
            Task { @MainActor in await runClipsKeyboardChild(out: out) }
            app.run()
        }
    #endif
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 688, height: 360), styleMask: [.borderless], backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false; window.backgroundColor = .black
    window.center(); window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    Task { @MainActor in
        do {
            var captures: [[String: Any]] = []
            for width in [400, 640] {
                for (appearance, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
                    let root = out.appendingPathComponent("data-\(appearance)-\(width)")
                    let store = PlannerStore(
                        file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
                    let clips = ClipsService(store: store, pasteboard: ClipsKeyboardPasteboard(), monitoring: false)
                    window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
                    for state in ["empty", "one", "populated", "cleared"] {
                        if state == "one" { clips.add(.text("Notes for the trail map"), source: "dropped") }
                        if state == "populated" {
                            for index in 1...8 { clips.add(.text("Reference item \(index)"), source: "dropped") }
                        }
                        if state == "cleared" { clips.clearShelf() }
                        let content = DropShelf(clips: clips).environmentObject(store)
                            .environment(\.accessibilityEnabled, true).environment(\.colorScheme, scheme)
                            .frame(width: CGFloat(width)).fixedSize(horizontal: false, vertical: true)
                        let height = ceil(NSHostingView(rootView: content).fittingSize.height)
                        let size = NSSize(width: CGFloat(width) + 48, height: height + 48)
                        let host = installClipsFixture(
                            content.padding(24).background(Color.black), in: window, size: size)
                        await settleClips()
                        let name = "\(appearance)-\(width)-\(state).png"
                        let url = out.appendingPathComponent(name)
                        try capture(host, size: size, to: url)
                        try writeClipsAccessibility(
                            host, to: url.deletingPathExtension().appendingPathExtension("ax.json"))
                        let nodes = clipsNodes(host, includingNavigationOrder: true)
                        try requireClips(
                            !nodes.contains {
                                clipsNames($0).contains("Add screenshots")
                                    || clipsNames($0).contains("Add copied items")
                            }, "Retired capture controls must be absent")
                        let slot = nodes.filter {
                            clipsAttribute($0, "accessibilityIdentifier") as? String == "shelf.drop"
                        }
                        try requireClips(slot.count == 1, "One dashed drop target is required")
                        let frame = try clipsFrame(slot[0], in: host)
                        let pngFrame =
                            host.isFlipped
                            ? frame
                            : CGRect(
                                x: frame.minX, y: size.height - frame.maxY, width: frame.width, height: frame.height)
                        let clear = try clipsFrame(clipsControl(AppL10n.text("Clear"), in: host), in: host)
                        try requireClips(clear.height >= 28 && clear.width >= 28, "Clear keeps a 28pt target")
                        if state == "populated" {
                            let scrolls = nodes.compactMap { $0 as? NSScrollView }.filter { $0.documentView != nil }
                            guard
                                let scroll = scrolls.first(where: {
                                    $0.documentView!.bounds.width > $0.contentView.bounds.width
                                })
                            else { throw PlannerError("Populated shelf must scroll horizontally.") }
                            scroll.contentView.scroll(
                                to: NSPoint(
                                    x: scroll.documentView!.bounds.width - scroll.contentView.bounds.width, y: 0))
                            scroll.reflectScrolledClipView(scroll.contentView)
                            try requireClips(
                                scroll.contentView.bounds.minX > 0, "Kept items remain reachable by scrolling")
                        }
                        captures.append([
                            "file": name, "width": size.width, "height": size.height, "stripWidth": width,
                            "appearance": appearance, "state": state, "clipCount": clips.clips.count,
                            "card": [24.0, 24, Double(width) + 24, height + 24],
                            "slot": [pngFrame.minX, pngFrame.minY, pngFrame.maxX, pngFrame.maxY],
                        ])
                    }
                }
            }
            try JSONSerialization.data(withJSONObject: captures, options: [.prettyPrinted, .sortedKeys]).write(
                to: out.appendingPathComponent("captures.json"))
            #if CLIPS_PREVIEW_REGRESSION
                try checkClipsKeyboard()
            #endif
            print("Drop shelf snapshots: \(captures.count). Actual shelf and durable clip storage.")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Drop shelf probe failed: \(error)\n".utf8)); exit(1)
        }
    }
    withExtendedLifetime(window) { app.run() }
}
