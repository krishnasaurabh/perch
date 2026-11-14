import AppKit
import EventKit
@testable import PlannerCore
import PerchUI
import SwiftUI
@testable import PerchApp

/// Exercises the production workspace, not a gallery or a replacement picker.
/// Runs outside the XCTest tool so system services see an unbundled process.
/// All storage is synthetic; this fixture refuses permission-enabled hosts.
private final class WorkspaceNavigationProbe {
    @MainActor
    func testTabEventConstruction() throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let forward = try workspaceKeyEvent(48, "\t", type: type, modifiers: [], windowNumber: 0)
            let backward = try workspaceKeyEvent(48, "\t", type: type, modifiers: .shift, windowNumber: 0)
            try requireEqual(forward.characters, "\t")
            try requireEqual(forward.charactersIgnoringModifiers, "\t")
            try requireEqual(backward.characters, "\u{19}")
            try requireEqual(backward.charactersIgnoringModifiers, "\u{19}")
            try requireFalse(backward.characters == forward.characters, "Back-tab must not encode forward Tab")
            try requireEqual(backward.modifierFlags, .shift)
            try requireEqual(backward.type, type)
            try requireEqual(backward.keyCode, 48)
        }
    }

    @MainActor
    func testKeyboardGroupSelectionTargetsAndMeasuredFocusAtCompactAndWideWidths() async throws {
        for width in [760.0, 1024.0] {
            let fixture = try WorkspaceNavigationFixture(width: width)
            defer {
                try? fixture.save("last-state")
                fixture.trace("last-state")
                fixture.close()
            }
            fixture.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            await fixture.settle()
            try require(fixture.window.isKeyWindow, "Keyboard fixture must own the key window")
            let initial = try fixture.pageFrames()
            let more = try fixture.control("workspace-more")
            let moreFrame = fixture.frame(more)
            try requireEqual(fixture.attribute(more, "accessibilityRole") as? String, "AXButton")
            try requireEqual(fixture.attribute(more, "accessibilityLabel") as? String, "More")
            try require(try fixture.bool(more, "isAccessibilityEnabled"))
            try requireAtLeast(moreFrame.width, ThemeTokens.minimumTarget)
            try requireAtLeast(moreFrame.height, ThemeTokens.minimumTarget)
            try fixture.assertHeaderLayout()
            try fixture.assertSelection(.home)
            try fixture.save("rest")

            try require(fixture.window.makeFirstResponder(fixture.destinations.before))
            await fixture.settle()
            try await fixture.key(48, "\t")
            try fixture.assertFocused("workspace-page-home")
            try fixture.assertFocusRing(.home)

            // Clamped boundaries and both interior directions are deliberate.
            for (code, characters, expected) in [
                (UInt16(123), "\u{f702}", NotchPage.home),
                (124, "\u{f703}", .week), (124, "\u{f703}", .clips),
                (123, "\u{f702}", .week), (119, "\u{f72b}", .insights),
                (124, "\u{f703}", .insights), (115, "\u{f729}", .home),
            ] {
                try await fixture.key(code, characters)
                try fixture.assertSelection(expected)
                try fixture.assertFocused("workspace-page-\(expected.rawValue)")
                try fixture.assertFocusRing(expected)
                try requireEqual(try fixture.pageFrames(), initial, "Selection and focus must not move any pill")
            }

            // There is one Tab stop for all four pages, followed by the real More menu.
            try await fixture.key(48, "\t")
            try fixture.assertFocused("workspace-more")
            try fixture.assertFocusRing(identifier: "workspace-more")
            try await fixture.inspectMoreMenu(usingKeyboard: true, undoEnabled: false)
            try fixture.assertFocused("workspace-more")
            try requireEqual(fixture.model.page, .home, "Tab does not activate another page")
            try await fixture.key(48, "\t", modifiers: .shift)
            try fixture.assertFocused("workspace-page-home")
            try fixture.assertFocusRing(.home)
            try await fixture.key(48, "\t", modifiers: .shift)
            try require(fixture.destinations.before.currentEditor() === fixture.window.firstResponder)
            try await fixture.key(48, "\t")
            try fixture.assertFocused("workspace-page-home")
            try await fixture.key(119, "\u{f72b}")
            try await fixture.key(48, "\t")
            try fixture.assertFocused("workspace-more")
            try await fixture.key(48, "\t", modifiers: .shift)
            try fixture.assertFocused("workspace-page-insights")
            try fixture.assertFocusRing(.insights)

            // Space activates the focused page, not the neighbouring menu or page.
            try await fixture.key(49, " ")
            try fixture.assertSelection(.insights)
            try requireNil(fixture.window.attachedSheet)
            try requireEqual(try fixture.file.load().tasks, [], "Navigation never edits planner tasks")
            try requireNil(fixture.model.captureFocusRequest)

            // Activate the real native menu action, including its Undo enablement.
            fixture.store.send(.addTasks(["Synthetic menu task"], day: nil, literal: true, agentID: nil))
            try requireEqual(fixture.store.planner.tasks.count, 1)
            try require(fixture.store.canUndo)
            await fixture.settle()
            try await fixture.inspectMoreMenu(usingKeyboard: false, undoEnabled: true, activateUndo: true)
            try requireEqual(try fixture.file.load().tasks, [], "More menu Undo reaches persisted storage")
        }
    }

    @MainActor
    func testPassivePresentationAndPageActivationDoNotStealKeyWindow() async throws {
        for width in [760.0, 1024.0] {
            let fixture = try WorkspaceNavigationFixture(width: width)
            defer {
                try? fixture.save("last-state")
                fixture.trace("last-state")
                fixture.close()
            }
            let other = NSWindow(
                contentRect: NSRect(x: 60, y: 60, width: 300, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            let field = NSTextField(string: "Synthetic foreground editor")
            other.contentView = field
            other.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try require(other.makeFirstResponder(field))
            await fixture.settle()
            defer { other.close() }
            try require(other.isKeyWindow, "Establish passive-opening positive control")
            let editor = try unwrap(field.currentEditor())

            fixture.model.open()
            fixture.window.orderFrontRegardless()
            await fixture.settle()
            try require(other.isKeyWindow)
            try require(other.firstResponder === editor)
            try requireFalse(fixture.window.isKeyWindow)
            try requireNil(fixture.model.captureFocusRequest)
            try requireFalse(fixture.model.pinned)
            for page in NotchPage.allCases {
                // Dispatch the actual button's AX action, not the model callback.
                try fixture.press(fixture.control("workspace-page-\(page.rawValue)"))
                await fixture.settle()
                try fixture.assertSelection(page)
                try require(other.isKeyWindow, "Passive page activation preserves the foreground editor")
                try require(other.firstResponder === editor)
                try requireFalse(fixture.window.isKeyWindow)
                try requireNil(fixture.model.captureFocusRequest)
            }
            try fixture.save("passive")
        }
    }
}

@MainActor
private final class WorkspaceNavigationFixture {
    let directory: URL
    let file: PlannerFile
    let store: PlannerStore
    let services: Services
    let model = NotchModel()
    let window: NotchPanel
    let destinations = WorkspaceDestinations()
    let width: Double
    let priorPolicy: NSApplication.ActivationPolicy
    let priorArguments: [String: Any]
    let priorData: String?

    init(width: Double) throws {
        // Exercise the real services without a test-host bundle identifier or live
        // calendar access. NotificationAccess returns before contacting the OS.
        try requireNil(Bundle.main.bundleIdentifier, "Probe must remain an unbundled executable")
        let calendarStatus = EKEventStore.authorizationStatus(for: .event)
        guard calendarStatus == .notDetermined || calendarStatus == .denied || calendarStatus == .restricted else {
            throw WorkspaceNavigationError.permissionEnabledHost
        }
        self.width = width
        priorPolicy = NSApplication.shared.activationPolicy()
        priorArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        priorData = ProcessInfo.processInfo.environment["PERCH_DATA"]
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        file = PlannerFile(url: directory.appendingPathComponent("planner.json"))
        var planner = Planner()
        planner.preferences.welcomeCompleted = true
        planner.preferences.catchCopies = false
        planner.preferences.catchScreenshots = false
        planner.preferences.resetHour = 0
        try file.save(planner)
        setenv("PERCH_DATA", file.url.path, 1)
        var arguments = priorArguments
        arguments["AppleKeyboardUIMode"] = 3
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        NSApp.setActivationPolicy(.accessory)
        store = PlannerStore(file: file, watching: false)
        try requireFalse(store.prefs.catchCopies, "Clipboard capture must remain disabled")
        try requireFalse(store.prefs.catchScreenshots, "Screenshot capture must remain disabled")
        services = Services(store: store)
        window = NotchPanel(frame: NSRect(x: 80, y: 180, width: width, height: 420))
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = false
        let host = NotchHostingView(
            rootView: WorkspaceNavigationHost(
                store: store, services: services, model: model, destinations: destinations
            )
            .environment(\.accessibilityEnabled, true)
            .environment(\.colorScheme, .dark))
        host.safeAreaRegions = []
        window.contentView = host
    }

    func close() {
        window.close()
        NSApp.setActivationPolicy(priorPolicy)
        UserDefaults.standard.setVolatileDomain(priorArguments, forName: UserDefaults.argumentDomain)
        if let priorData { setenv("PERCH_DATA", priorData, 1) } else { unsetenv("PERCH_DATA") }
        try? FileManager.default.removeItem(at: directory)
    }

    func settle() async {
        try? await Task.sleep(nanoseconds: 180_000_000)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) async throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try workspaceKeyEvent(
                code, characters, type: type, modifiers: modifiers, windowNumber: window.windowNumber)
            report(
                "Workspace key event code=\(code) type=\(type.rawValue) modifiers=\(modifiers.rawValue) "
                    + "characters=\(event.characters?.unicodeScalars.map(\.value) ?? []) "
                    + "ignoringModifiers=\(event.charactersIgnoringModifiers?.unicodeScalars.map(\.value) ?? [])")
            NSApp.sendEvent(event)
        }
        await settle()
        trace("key \(code) modifiers=\(modifiers.rawValue)")
    }

    func control(_ identifier: String) throws -> NSObject {
        let matches = nodes(window).filter { attribute($0, "accessibilityIdentifier") as? String == identifier }
        guard matches.count == 1, let node = matches.first else {
            trace("missing/ambiguous \(identifier)")
            throw WorkspaceNavigationError.missingControl(identifier)
        }
        return node
    }

    func assertFocused(_ identifier: String) throws {
        trace("expect focus \(identifier)")
        try require(window.isKeyWindow)
        let node = try control(identifier)
        try require(try bool(node, "isAccessibilityFocused"), "Native focus must be \(identifier)")
    }

    func assertSelection(_ page: NotchPage) throws {
        try requireEqual(model.page, page)
        for candidate in NotchPage.allCases {
            let node = try control("workspace-page-\(candidate.rawValue)")
            try requireEqual(attribute(node, "accessibilityRole") as? String, "AXButton")
            try requireEqual(attribute(node, "accessibilityLabel") as? String, candidate.title)
            try requireEqual(
                attribute(node, "accessibilityValue") as? String,
                candidate == page ? "Selected" : "Not selected")
            try require(try bool(node, "isAccessibilityEnabled"))
        }
    }

    func pageFrames() throws -> [NSRect] {
        try NotchPage.allCases.map { frame(try control("workspace-page-\($0.rawValue)")) }
    }

    func assertHeaderLayout() throws {
        let rects = try pageFrames() + [frame(control("workspace-more"))]
        let host = try unwrap(window.contentView)
        let visible = window.convertToScreen(host.convert(host.bounds, to: nil))
        // Synthetic 180x32 housing at the actual workspace's top centre.
        let workspace = destinations.workspaceFrame
        try requireGreater(workspace.width, 0)
        let cameraLocal = NSRect(x: workspace.midX - 90, y: workspace.minY, width: 180, height: 32)
        let camera = window.convertToScreen(host.convert(cameraLocal, to: nil))
        for rect in rects {
            try requireAtLeast(rect.width, ThemeTokens.minimumTarget)
            try requireAtLeast(rect.height, ThemeTokens.minimumTarget)
            let ringBounds = rect.insetBy(
                dx: -(Theme.focusGap + Theme.focusWidth),
                dy: -(Theme.focusGap + Theme.focusWidth))
            try require(visible.contains(ringBounds), "Target and ring remain inside the workspace at \(width)")
            try requireFalse(ringBounds.intersects(camera), "Navigation must remain beside the camera housing")
        }
        for index in rects.indices.dropLast() {
            try requireFalse(rects[index].intersects(rects[index + 1]))
        }
    }

    func assertFocusRing(_ page: NotchPage) throws {
        try assertFocusRing(identifier: "workspace-page-\(page.rawValue)")
    }

    func assertFocusRing(identifier: String) throws {
        try assertFocused(identifier)
        let node = try control(identifier)
        let host = try unwrap(window.contentView)
        let target = host.convert(window.convertFromScreen(frame(node)), from: nil)
        let bitmap = try snapshot()
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let y = Int((host.isFlipped ? target.midY : host.bounds.height - target.midY) * scale)
        let start = Int((target.minX - Theme.focusGap - Theme.focusWidth - 2) * scale)
        let end = Int((target.maxX + Theme.focusGap + Theme.focusWidth + 2) * scale)
        let matches = (max(0, start)..<min(bitmap.pixelsWide, end)).filter { x in
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            let token = ThemeTokens.dark.info
            return abs(c.redComponent - Double((token >> 16) & 255) / 255) < 0.07
                && abs(c.greenComponent - Double((token >> 8) & 255) / 255) < 0.07
                && abs(c.blueComponent - Double(token & 255) / 255) < 0.07
        }
        let left = matches.filter { CGFloat($0) < target.minX * scale }
        let right = matches.filter { CGFloat($0) > target.maxX * scale }
        try requireEqual(
            Double(left.count) / scale, ThemeTokens.focusWidth, accuracy: 1,
            "Measured left focus stroke")
        try requireEqual(
            Double(right.count) / scale, ThemeTokens.focusWidth, accuracy: 1,
            "Measured right focus stroke")
        if let edge = left.max() {
            try requireEqual(target.minX - CGFloat(edge + 1) / scale, ThemeTokens.focusGap, accuracy: 1)
        }
        if let edge = right.min() {
            try requireEqual(CGFloat(edge) / scale - target.maxX, ThemeTokens.focusGap, accuracy: 1)
        }
        try save("focus-\(identifier)")
    }

    func inspectMoreMenu(usingKeyboard: Bool, undoEnabled: Bool, activateUndo: Bool = false) async throws {
        let observation = WorkspaceMenuObservation(activateUndo: activateUndo)
        observation.start()
        defer { observation.stop() }
        if usingKeyboard {
            try await key(49, " ")
        } else {
            try press(control("workspace-more"))
            await settle()
        }
        let menu = try unwrap(observation.menu)
        try requireFalse(observation.timedOut, "Native More menu must begin tracking")
        try requireEqual(menu.items.map(\.title), ["Undo", "", "Your week", "History", "Projects", "Settings…"])
        try require(menu.items[1].isSeparatorItem)
        try requireEqual(menu.items[0].isEnabled, undoEnabled)
        try require(menu.items[2].isEnabled)
        try require(menu.items[3].isEnabled)
        try requireEqual(observation.activatedUndo, activateUndo)
    }

    func snapshot() throws -> NSBitmapImageRep {
        let host = try unwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        let bitmap = try unwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    func save(_ name: String) throws {
        // CI already uploads native-diagnostics on failure. Outputs never enter source control.
        guard let root = ProcessInfo.processInfo.environment["RUNNER_TEMP"] else { return }
        let output = URL(fileURLWithPath: root).appendingPathComponent("native-diagnostics/workspace-navigation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try unwrap(snapshot().representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("\(Int(width))-\(name).png"))
    }

    func press(_ node: NSObject) throws {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let implementation = try unwrap(node.responds(to: selector) ? node.method(for: selector) : nil)
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        try require(unsafeBitCast(implementation, to: Press.self)(node, selector))
    }

    func bool(_ node: NSObject, _ name: String) throws -> Bool {
        let selector = NSSelectorFromString(name)
        let implementation = try unwrap(node.responds(to: selector) ? node.method(for: selector) : nil)
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(implementation, to: Getter.self)(node, selector)
    }

    func frame(_ node: NSObject) -> NSRect {
        guard node.responds(to: NSSelectorFromString("accessibilityFrame")),
            let value = node.value(forKey: "accessibilityFrame") as? NSValue
        else { return .zero }
        return value.rectValue
    }

    func attribute(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
    }

    func nodes(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            var children = ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"]
                .flatMap { (attribute(node, $0) as? [NSObject]) ?? [] }
            if let view = node as? NSView { children += view.subviews }
            if let window = node as? NSWindow, let content = window.contentView { children.append(content) }
            return [node] + children.flatMap(walk)
        }
        return walk(root)
    }

    func trace(_ context: String) {
        let lines = nodes(window).filter {
            attribute($0, "accessibilityRole") != nil
        }.map {
            "\(type(of: $0)) id=\(attribute($0, "accessibilityIdentifier") ?? "?") "
                + "role=\(attribute($0, "accessibilityRole") ?? "?") "
                + "label=\(attribute($0, "accessibilityLabel") ?? "?") "
                + "value=\(attribute($0, "accessibilityValue") ?? "?") frame=\(frame($0)) "
                + "focused=\((try? bool($0, "isAccessibilityFocused")) ?? false)"
        }
        FileHandle.standardError.write(
            Data(
                ("Workspace \(width): \(context) key=\(window.isKeyWindow)\n"
                    + lines.joined(separator: "\n") + "\n").utf8))
    }
}

/// Close the native tracking loop on its own run-loop mode, not a blocked task.
@MainActor
private final class WorkspaceMenuObservation: NSObject {
    let activateUndo: Bool
    private let deadline = ProcessInfo.processInfo.systemUptime + 5
    private var timer: Timer?
    private(set) var menu: NSMenu?
    private(set) var timedOut = false
    private(set) var activatedUndo = false

    init(activateUndo: Bool) { self.activateUndo = activateUndo }

    func start() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(beganTracking(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(inspect), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func beganTracking(_ notification: Notification) {
        guard let tracked = notification.object as? NSMenu, tracked.title == "More" else { return }
        menu = tracked
    }

    @objc private func inspect() {
        if let menu {
            if activateUndo, !activatedUndo, let first = menu.items.first, first.isEnabled {
                menu.performActionForItem(at: 0)
                activatedUndo = true
            }
            menu.cancelTracking()
            timer?.invalidate()
        } else if ProcessInfo.processInfo.systemUptime >= deadline {
            timedOut = true
            timer?.invalidate()
        }
    }
}

private enum WorkspaceNavigationError: Error {
    case permissionEnabledHost
    case assertion(String, String, UInt)
    case missingControl(String)
}

@MainActor
private final class WorkspaceDestinations {
    var before = NSTextField(string: "Before workspace")
    var after = NSTextField(string: "After workspace")
    var workspaceFrame = CGRect.zero
}

private struct WorkspaceDestination: NSViewRepresentable {
    let field: NSTextField
    func makeNSView(context: Context) -> NSTextField { field }
    func updateNSView(_ view: NSTextField, context: Context) {}
}

private struct WorkspaceNavigationHost: View {
    let store: PlannerStore
    let services: Services
    let model: NotchModel
    let destinations: WorkspaceDestinations

    var body: some View {
        VStack(spacing: 8) {
            WorkspaceDestination(field: destinations.before).frame(height: 24)
            WorkspaceView(notchHeight: 32)
                .environmentObject(store).environmentObject(services).environmentObject(model)
                .background(
                    GeometryReader { geometry in
                        Color.clear.onAppear {
                            destinations.workspaceFrame = geometry.frame(in: .named("workspace-fixture"))
                        }
                    })
            WorkspaceDestination(field: destinations.after).frame(height: 24)
        }
        .padding(12)
        .background(Color.black)
        .coordinateSpace(name: "workspace-fixture")
    }
}

@MainActor
private func workspaceKeyEvent(
    _ code: UInt16, _ characters: String, type: NSEvent.EventType,
    modifiers: NSEvent.ModifierFlags, windowNumber: Int
) throws -> NSEvent {
    // AppKit represents Shift-Tab with the back-tab character in BOTH fields.
    // charactersIgnoringModifiers still preserves Shift; flags alone are insufficient.
    let eventCharacters = code == 48 && modifiers.contains(.shift) ? "\u{19}" : characters
    return try unwrap(
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber,
            context: nil, characters: eventCharacters, charactersIgnoringModifiers: eventCharacters,
            isARepeat: false, keyCode: code))
}

private func failure(_ message: String, file: StaticString, line: UInt) -> WorkspaceNavigationError {
    .assertion(message, String(describing: file), line)
}

private func require(
    _ value: @autoclosure () throws -> Bool, _ message: String = "Expected true",
    file: StaticString = #fileID, line: UInt = #line
) throws {
    guard try value() else { throw failure(message, file: file, line: line) }
}

private func requireFalse(
    _ value: @autoclosure () throws -> Bool, _ message: String = "Expected false",
    file: StaticString = #fileID, line: UInt = #line
) throws {
    try require(!(try value()), message, file: file, line: line)
}

private func requireEqual<T: Equatable>(
    _ actual: T, _ expected: T, _ message: String = "Values differ",
    file: StaticString = #fileID, line: UInt = #line
) throws {
    try require(actual == expected, "\(message): \(actual) != \(expected)", file: file, line: line)
}

private func requireEqual(
    _ actual: Double, _ expected: Double, accuracy: Double, _ message: String = "Values differ",
    file: StaticString = #fileID, line: UInt = #line
) throws {
    try require(abs(actual - expected) <= accuracy, "\(message): \(actual) != \(expected)", file: file, line: line)
}

private func requireEqual(
    _ actual: CGFloat, _ expected: CGFloat, accuracy: CGFloat, _ message: String = "Values differ",
    file: StaticString = #fileID, line: UInt = #line
) throws {
    try require(abs(actual - expected) <= accuracy, "\(message): \(actual) != \(expected)", file: file, line: line)
}

private func requireNil<T>(
    _ value: T?, _ message: String = "Expected nil", file: StaticString = #fileID, line: UInt = #line
) throws {
    try require(value == nil, message, file: file, line: line)
}

private func requireAtLeast<T: Comparable>(
    _ actual: T, _ minimum: T, file: StaticString = #fileID, line: UInt = #line
) throws {
    try require(actual >= minimum, "\(actual) is below \(minimum)", file: file, line: line)
}

private func requireGreater<T: Comparable>(
    _ actual: T, _ minimum: T, file: StaticString = #fileID, line: UInt = #line
) throws {
    try require(actual > minimum, "\(actual) is not above \(minimum)", file: file, line: line)
}

private func unwrap<T>(
    _ value: T?, file: StaticString = #fileID, line: UInt = #line
) throws -> T {
    guard let value else { throw failure("Required value is missing", file: file, line: line) }
    return value
}

private func report(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let application = NSApplication.shared
Task { @MainActor in
    do {
        let probe = WorkspaceNavigationProbe()
        try probe.testTabEventConstruction()
        report("PASS: workspace native forward/back-tab event construction")
        try await probe.testKeyboardGroupSelectionTargetsAndMeasuredFocusAtCompactAndWideWidths()
        report("PASS: workspace keyboard, selection, targets, layout and focus rings at 760pt and 1024pt")
        try await probe.testPassivePresentationAndPageActivationDoNotStealKeyWindow()
        report("PASS: workspace passive presentation and page activation at 760pt and 1024pt")
        exit(0)
    } catch {
        report("FAIL: workspace navigation: \(error)")
        exit(1)
    }
}
application.run()
