import AppKit
import EventKit
import PerchUI
@testable import PlannerCore
import SwiftUI
import XCTest
@testable import PerchApp

/// Exercises the production workspace, not a gallery or a replacement picker.
/// All storage is synthetic; this fixture refuses permission-enabled hosts.
final class WorkspaceNavigationTests: XCTestCase {
    @MainActor
    func testKeyboardGroupSelectionTargetsAndMeasuredFocusAtCompactAndWideWidths() async throws {
        for width in [760.0, 1024.0] {
            let fixture = try WorkspaceNavigationFixture(width: width)
            defer { fixture.close() }
            fixture.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            await fixture.settle()
            XCTAssertTrue(fixture.window.isKeyWindow, "Keyboard fixture must own the key window")
            let initial = try fixture.pageFrames()
            let more = try fixture.control("workspace-more")
            let moreFrame = fixture.frame(more)
            XCTAssertGreaterThanOrEqual(moreFrame.width, ThemeTokens.minimumTarget)
            XCTAssertGreaterThanOrEqual(moreFrame.height, ThemeTokens.minimumTarget)
            try fixture.assertHeaderLayout()
            try fixture.assertSelection(.home)
            try fixture.save("rest")

            XCTAssertTrue(fixture.window.makeFirstResponder(fixture.destinations.before))
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
                XCTAssertEqual(try fixture.pageFrames(), initial, "Selection and focus must not move any pill")
            }

            // There is one Tab stop for all four pages, followed by the real More menu.
            try await fixture.key(48, "\t")
            try fixture.assertFocused("workspace-more")
            try fixture.assertFocusRing(identifier: "workspace-more")
            XCTAssertEqual(fixture.model.page, .home, "Tab does not activate another page")
            try await fixture.key(48, "\t", modifiers: .shift)
            try fixture.assertFocused("workspace-page-home")
            try await fixture.key(48, "\t", modifiers: .shift)
            XCTAssertTrue(fixture.destinations.before.currentEditor() === fixture.window.firstResponder)
            try await fixture.key(48, "\t")
            try fixture.assertFocused("workspace-page-home")
            try await fixture.key(119, "\u{f72b}")
            try await fixture.key(48, "\t")
            try fixture.assertFocused("workspace-more")
            try await fixture.key(48, "\t", modifiers: .shift)
            try fixture.assertFocused("workspace-page-insights")

            // Space activates the focused page, not the neighbouring menu or page.
            try await fixture.key(49, " ")
            try fixture.assertSelection(.insights)
            XCTAssertNil(fixture.window.attachedSheet)
            XCTAssertEqual(try fixture.file.load().tasks, [], "Navigation never edits planner tasks")
            XCTAssertNil(fixture.model.captureFocusRequest)
        }
    }

    @MainActor
    func testPassivePresentationAndPageActivationDoNotStealKeyWindow() async throws {
        for width in [760.0, 1024.0] {
            let fixture = try WorkspaceNavigationFixture(width: width)
            defer { fixture.close() }
            let other = NSWindow(
                contentRect: NSRect(x: 60, y: 60, width: 300, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            let field = NSTextField(string: "Synthetic foreground editor")
            other.contentView = field
            other.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            XCTAssertTrue(other.makeFirstResponder(field))
            await fixture.settle()
            defer { other.close() }
            XCTAssertTrue(other.isKeyWindow, "Establish passive-opening positive control")
            let editor = try XCTUnwrap(field.currentEditor())

            fixture.model.open()
            fixture.window.orderFrontRegardless()
            await fixture.settle()
            XCTAssertTrue(other.isKeyWindow)
            XCTAssertTrue(other.firstResponder === editor)
            XCTAssertFalse(fixture.window.isKeyWindow)
            XCTAssertNil(fixture.model.captureFocusRequest)
            XCTAssertFalse(fixture.model.pinned)
            for page in NotchPage.allCases {
                // Dispatch the actual button's AX action, not the model callback.
                try fixture.press(fixture.control("workspace-page-\(page.rawValue)"))
                await fixture.settle()
                try fixture.assertSelection(page)
                XCTAssertTrue(other.isKeyWindow, "Passive page activation preserves the foreground editor")
                XCTAssertTrue(other.firstResponder === editor)
                XCTAssertFalse(fixture.window.isKeyWindow)
                XCTAssertNil(fixture.model.captureFocusRequest)
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
        // Services' production constructor is intentionally exercised. Never let it
        // read calendars on a developer's permission-enabled machine.
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
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code))
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
        XCTAssertTrue(window.isKeyWindow)
        let node = try control(identifier)
        XCTAssertTrue(try bool(node, "isAccessibilityFocused"), "Native focus must be \(identifier)")
    }

    func assertSelection(_ page: NotchPage) throws {
        XCTAssertEqual(model.page, page)
        for candidate in NotchPage.allCases {
            let node = try control("workspace-page-\(candidate.rawValue)")
            XCTAssertEqual(attribute(node, "accessibilityRole") as? String, "AXButton")
            XCTAssertEqual(attribute(node, "accessibilityLabel") as? String, candidate.title)
            XCTAssertEqual(
                attribute(node, "accessibilityValue") as? String,
                candidate == page ? "Selected" : "Not selected")
            XCTAssertTrue(try bool(node, "isAccessibilityEnabled"))
        }
    }

    func pageFrames() throws -> [NSRect] {
        try NotchPage.allCases.map { frame(try control("workspace-page-\($0.rawValue)")) }
    }

    func assertHeaderLayout() throws {
        let rects = try pageFrames() + [frame(control("workspace-more"))]
        let host = try XCTUnwrap(window.contentView)
        let visible = window.convertToScreen(host.convert(host.bounds, to: nil))
        // Synthetic 180x32 housing at the actual workspace's top centre.
        let workspace = destinations.workspaceFrame
        XCTAssertGreaterThan(workspace.width, 0)
        let cameraLocal = NSRect(x: workspace.midX - 90, y: workspace.minY, width: 180, height: 32)
        let camera = window.convertToScreen(host.convert(cameraLocal, to: nil))
        for rect in rects {
            XCTAssertGreaterThanOrEqual(rect.width, ThemeTokens.minimumTarget)
            XCTAssertGreaterThanOrEqual(rect.height, ThemeTokens.minimumTarget)
            let ringBounds = rect.insetBy(
                dx: -(Theme.focusGap + Theme.focusWidth),
                dy: -(Theme.focusGap + Theme.focusWidth))
            XCTAssertTrue(visible.contains(ringBounds), "Target and ring remain inside the workspace at \(width)")
            XCTAssertFalse(ringBounds.intersects(camera), "Navigation must remain beside the camera housing")
        }
        for index in rects.indices.dropLast() {
            XCTAssertFalse(rects[index].intersects(rects[index + 1]))
        }
    }

    func assertFocusRing(_ page: NotchPage) throws {
        try assertFocusRing(identifier: "workspace-page-\(page.rawValue)")
    }

    func assertFocusRing(identifier: String) throws {
        try assertFocused(identifier)
        let node = try control(identifier)
        let host = try XCTUnwrap(window.contentView)
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
        XCTAssertEqual(
            Double(left.count) / scale, ThemeTokens.focusWidth, accuracy: 1,
            "Measured left focus stroke")
        XCTAssertEqual(
            Double(right.count) / scale, ThemeTokens.focusWidth, accuracy: 1,
            "Measured right focus stroke")
        if let edge = left.max() {
            XCTAssertEqual(target.minX - CGFloat(edge + 1) / scale, ThemeTokens.focusGap, accuracy: 1)
        }
        if let edge = right.min() {
            XCTAssertEqual(CGFloat(edge) / scale - target.maxX, ThemeTokens.focusGap, accuracy: 1)
        }
        try save("focus-\(identifier)")
    }

    func snapshot() throws -> NSBitmapImageRep {
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    func save(_ name: String) throws {
        // CI already uploads native-diagnostics on failure. Outputs never enter source control.
        guard let root = ProcessInfo.processInfo.environment["RUNNER_TEMP"] else { return }
        let output = URL(fileURLWithPath: root).appendingPathComponent("native-diagnostics/workspace-navigation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(snapshot().representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("\(Int(width))-\(name).png"))
    }

    func press(_ node: NSObject) throws {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let implementation = try XCTUnwrap(node.responds(to: selector) ? node.method(for: selector) : nil)
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(implementation, to: Press.self)(node, selector))
    }

    func bool(_ node: NSObject, _ name: String) throws -> Bool {
        let selector = NSSelectorFromString(name)
        let implementation = try XCTUnwrap(node.responds(to: selector) ? node.method(for: selector) : nil)
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
            (attribute($0, "accessibilityIdentifier") as? String)?.hasPrefix("workspace-") == true
        }.map {
            "\(attribute($0, "accessibilityIdentifier") ?? "?") role=\(attribute($0, "accessibilityRole") ?? "?") "
                + "value=\(attribute($0, "accessibilityValue") ?? "?") frame=\(frame($0)) "
                + "focused=\((try? bool($0, "isAccessibilityFocused")) ?? false)"
        }
        FileHandle.standardError.write(
            Data(
                ("Workspace \(width): \(context) key=\(window.isKeyWindow)\n"
                    + lines.joined(separator: "\n") + "\n").utf8))
    }
}

private enum WorkspaceNavigationError: Error {
    case permissionEnabledHost
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
