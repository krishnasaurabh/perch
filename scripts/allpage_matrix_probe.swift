// CI-only all-page matrix probe. Renders the production Settings, Dashboard, Welcome,
// Workspace (Week), Clips and Details surfaces in a real window and drives them with real
// NSEvent key events plus measured AX frames and rendered pixels.
//
// Nothing here mutates the user's world: the planner is a synthetic file in a temporary
// directory, the clipboard is a recording fake, permissions are only ever *read* (the probe
// stays unbundled, so notification access refuses before contacting the OS, and no request
// button is ever pressed), and every measurement has a probe-local negative control that
// proves the measurement itself can go red.
import AppKit
import ApplicationServices
import EventKit
import PerchUI
import ServiceManagement
@testable import PerchApp
@testable import PlannerCore
import SwiftUI

// MARK: - Result plumbing

struct MatrixFailure: Error, CustomStringConvertible {
    let label: String
    var description: String { label }
}

@MainActor
final class MatrixReport {
    private(set) var passed: [String] = []
    private(set) var failed: [String] = []
    private(set) var evidence: [String: Any] = [:]

    func pass(_ label: String) {
        passed.append(label)
        print("PASS: \(label)")
    }

    func fail(_ group: String, _ detail: String) {
        failed.append("\(group): \(detail)")
        print("FAIL: \(group): \(detail)")
    }

    func require(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") throws {
        guard condition else {
            let extra = detail()
            throw MatrixFailure(label: extra.isEmpty ? label : "\(label) [\(extra)]")
        }
        pass(label)
    }

    /// One group never aborts the run: every failure is reported, so a deliberately broken
    /// scratch copy of the product produces all of its red observations in a single run.
    func group(_ name: String, _ body: @MainActor () async throws -> Void) async {
        do {
            try await body()
        } catch let failure as MatrixFailure {
            fail(name, failure.label)
        } catch {
            fail(name, "\(error)")
        }
    }

    func record(_ key: String, _ value: Any) { evidence[key] = value }

    func finish(output: URL) -> Never {
        print("All-page matrix: \(passed.count) passed, \(failed.count) failed")
        for failure in failed { print("RED: \(failure)") }
        let payload: [String: Any] = [
            "passed": passed, "failed": failed, "assertions": passed.count + failed.count,
            "evidence": evidence,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("matrix-evidence.json"))
        }
        exit(failed.isEmpty ? 0 : 1)
    }
}

// MARK: - Native helpers

@MainActor
func mxAttribute(_ node: NSObject, _ name: String) -> Any? {
    let selector = NSSelectorFromString(name)
    return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
}

@MainActor
func mxNodes(_ root: NSObject) -> [NSObject] {
    var seen = Set<ObjectIdentifier>()
    @MainActor func walk(_ node: NSObject, _ depth: Int) -> [NSObject] {
        guard depth < 80, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
        var children = ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"]
            .flatMap { (mxAttribute(node, $0) as? [NSObject]) ?? [] }
        if let view = node as? NSView { children += view.subviews }
        if let window = node as? NSWindow, let content = window.contentView { children.append(content) }
        if let window = node as? NSWindow, let sheet = window.attachedSheet { children.append(sheet) }
        return [node] + children.flatMap { walk($0, depth + 1) }
    }
    return walk(root, 0)
}

@MainActor
func mxIdentifier(_ node: NSObject) -> String? { mxAttribute(node, "accessibilityIdentifier") as? String }

@MainActor
func mxLabel(_ node: NSObject) -> String? {
    for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
        if let value = mxAttribute(node, name) as? String, !value.isEmpty { return value }
    }
    return nil
}

@MainActor
func mxRole(_ node: NSObject) -> String? { mxAttribute(node, "accessibilityRole") as? String }

@MainActor
func mxBool(_ node: NSObject, _ name: String) throws -> Bool {
    let selector = NSSelectorFromString(name)
    guard node.responds(to: selector), let implementation = node.method(for: selector) else {
        throw MatrixFailure(label: "\(type(of: node)) does not answer \(name)")
    }
    typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
    return unsafeBitCast(implementation, to: Getter.self)(node, selector)
}

@MainActor
func mxFrame(_ node: NSObject) -> NSRect {
    guard node.responds(to: NSSelectorFromString("accessibilityFrame")),
        let value = node.value(forKey: "accessibilityFrame") as? NSValue
    else { return .zero }
    return value.rectValue
}

@MainActor
func mxIdentified(_ root: NSObject, _ identifier: String) throws -> NSObject {
    let matches = mxNodes(root).filter { mxIdentifier($0) == identifier }
    guard matches.count == 1, let node = matches.first else {
        throw MatrixFailure(label: "expected one \(identifier), saw \(matches.count)")
    }
    return node
}

@MainActor
func mxFind(_ root: NSObject, label: String) -> NSObject? {
    mxNodes(root).first { mxLabel($0) == label }
}

@MainActor
func mxText(_ root: NSObject) -> [String] {
    mxNodes(root).compactMap { mxLabel($0) }
}

@MainActor
func mxHas(_ root: NSObject, _ text: String) -> Bool { mxText(root).contains(text) }

@MainActor
func mxHasContaining(_ root: NSObject, _ fragment: String) -> Bool {
    mxText(root).contains { $0.contains(fragment) }
}

/// Labels of rendered static text only: typing into a search field must not be mistaken for a
/// matching task line.
@MainActor
func mxStaticTexts(_ root: NSObject) -> [String] {
    mxNodes(root).filter { mxRole($0) == "AXStaticText" }.compactMap { mxLabel($0) }
}

@MainActor
func mxPress(_ node: NSObject) throws {
    let selector = NSSelectorFromString("accessibilityPerformPress")
    guard node.responds(to: selector), let implementation = node.method(for: selector) else {
        throw MatrixFailure(label: "\(type(of: node)) does not support AX press")
    }
    typealias Press = @convention(c) (AnyObject, Selector) -> Bool
    let performed = unsafeBitCast(implementation, to: Press.self)(node, selector)
    guard performed else { throw MatrixFailure(label: "AX press refused by \(mxIdentifier(node) ?? "control")") }
}

@MainActor
func mxFocusedNode(_ window: NSWindow) -> NSObject? {
    mxNodes(window).first { (try? mxBool($0, "isAccessibilityFocused")) == true }
}

@MainActor
func mxFocusIdentity(_ window: NSWindow) -> String? {
    guard let node = mxFocusedNode(window) else { return nil }
    return mxIdentifier(node) ?? mxLabel(node) ?? mxRole(node)
}

@MainActor
func mxAssertFocused(
    _ window: NSWindow, _ identity: String, _ label: String, report: MatrixReport
) throws {
    let observed = mxFocusIdentity(window)
    try report.require(observed == identity, label, "observed \(observed ?? "none")")
}

@MainActor
func mxKeyEvent(
    _ code: UInt16, _ characters: String, type: NSEvent.EventType,
    modifiers: NSEvent.ModifierFlags, windowNumber: Int
) throws -> NSEvent {
    // AppKit encodes Shift-Tab as the back-tab character in both fields.
    let encoded = code == 48 && modifiers.contains(.shift) ? "\u{19}" : characters
    guard
        let event = NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber,
            context: nil, characters: encoded, charactersIgnoringModifiers: encoded,
            isARepeat: false, keyCode: code)
    else { throw MatrixFailure(label: "could not build key event \(code)") }
    return event
}

@MainActor
func mxKey(_ window: NSWindow, _ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = [])
    async throws
{
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        let event = try mxKeyEvent(
            code, characters, type: type, modifiers: modifiers, windowNumber: window.windowNumber)
        NSApp.sendEvent(event)
    }
    await mxSettle()
}

@MainActor
func mxSettle(_ seconds: Double = 0.2) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    NSApp.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
}

@MainActor
func mxClick(host: NSView, window: NSWindow, at rect: NSRect) {
    let local = CGPoint(x: rect.midX, y: host.isFlipped ? rect.midY : host.bounds.height - rect.midY)
    let location = host.convert(local, to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard
            let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { return }
        NSApp.sendEvent(event)
    }
}

@MainActor
func mxBitmap(_ host: NSView) throws -> NSBitmapImageRep {
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw MatrixFailure(label: "no bitmap for host")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return bitmap
}

@MainActor
func mxSave(_ host: NSView, _ url: URL) throws {
    let bitmap = try mxBitmap(host)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw MatrixFailure(label: "no PNG for \(url.lastPathComponent)")
    }
    try png.write(to: url)
}

/// Host-space rectangle for an accessibility frame reported in screen coordinates.
@MainActor
func mxHostRect(_ node: NSObject, window: NSWindow, host: NSView) -> NSRect {
    let screen = mxFrame(node)
    guard screen != .zero else { return .zero }
    return host.convert(window.convertFromScreen(screen), from: nil)
}

/// Top-down bitmap row for a host-space y coordinate, matching the coordinate space that
/// NSHostingView reports to accessibility.
@MainActor
func mxRow(_ y: CGFloat, host: NSView, bitmap: NSBitmapImageRep) -> Int {
    let scale = CGFloat(bitmap.pixelsWide) / max(1, host.bounds.width)
    let flipped = host.isFlipped ? y : host.bounds.height - y
    return min(bitmap.pixelsHigh - 1, max(0, Int(flipped * scale)))
}

@MainActor
func mxScale(_ host: NSView, _ bitmap: NSBitmapImageRep) -> CGFloat {
    CGFloat(bitmap.pixelsWide) / max(1, host.bounds.width)
}

/// Opaque sRGB colour for a shared palette token. Probes measure the pixel a known ink paints,
/// so the reference must not be resolved through the current app appearance.
@MainActor
func mxTokenColor(_ value: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
        blue: CGFloat(value & 255) / 255, alpha: 1)
}

@MainActor
func mxNear(_ color: NSColor, _ reference: NSColor, tolerance: CGFloat = 0.08) -> Bool {
    guard let a = color.usingColorSpace(.sRGB), let b = reference.usingColorSpace(.sRGB) else { return false }
    return abs(a.redComponent - b.redComponent) <= tolerance
        && abs(a.greenComponent - b.greenComponent) <= tolerance
        && abs(a.blueComponent - b.blueComponent) <= tolerance
}

@MainActor
func mxBand(_ rect: NSRect, host: NSView, bitmap: NSBitmapImageRep, inset: CGFloat = 1)
    -> (x0: Int, x1: Int, y0: Int, y1: Int)
{
    let scale = mxScale(host, bitmap)
    let x0 = max(0, Int((rect.minX + inset) * scale))
    let x1 = min(bitmap.pixelsWide, Int((rect.maxX - inset) * scale))
    let y0 = mxRow(rect.minY + inset, host: host, bitmap: bitmap)
    let y1 = mxRow(rect.maxY - inset, host: host, bitmap: bitmap)
    return (x0, max(x0, x1), min(y0, y1), max(y0, y1))
}

/// Rows of a host-space band that contain at least `minimum` pixels near `ink`.
@MainActor
func mxInkRows(
    _ bitmap: NSBitmapImageRep, host: NSView, band: NSRect, ink: NSColor, minimum: Int = 2
) -> [Int] {
    let area = mxBand(band, host: host, bitmap: bitmap)
    guard area.x1 > area.x0, area.y1 > area.y0 else { return [] }
    var rows: [Int] = []
    for y in area.y0..<area.y1 {
        var hits = 0
        for x in area.x0..<area.x1 {
            guard let pixel = bitmap.colorAt(x: x, y: y) else { continue }
            if mxNear(pixel, ink) {
                hits += 1
                if hits >= minimum { break }
            }
        }
        if hits >= minimum { rows.append(y) }
    }
    return rows
}

@MainActor
func mxContrast(_ a: NSColor, _ b: NSColor) -> Double {
    func luminance(_ color: NSColor) -> Double {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.redComponent) + 0.7152 * channel(rgb.greenComponent)
            + 0.0722 * channel(rgb.blueComponent)
    }
    let first = luminance(a), second = luminance(b)
    return (max(first, second) + 0.05) / (min(first, second) + 0.05)
}

/// Most common colour in a band: the rendered background behind real text.
@MainActor
func mxDominant(_ bitmap: NSBitmapImageRep, host: NSView, band: NSRect) -> NSColor? {
    let area = mxBand(band, host: host, bitmap: bitmap)
    guard area.x1 > area.x0, area.y1 > area.y0 else { return nil }
    var counts: [String: Int] = [:]
    var colors: [String: NSColor] = [:]
    for y in area.y0..<area.y1 {
        for x in area.x0..<area.x1 {
            guard let rgb = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let key = String(
                format: "%03d-%03d-%03d", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
                Int(rgb.blueComponent * 255))
            counts[key, default: 0] += 1
            colors[key] = rgb
        }
    }
    guard let best = counts.max(by: { $0.value < $1.value }) else { return nil }
    return colors[best.key]
}

/// Pixel closest to `ink` inside a band: the glyph core, not an antialiased edge.
@MainActor
func mxInkSample(
    _ bitmap: NSBitmapImageRep, host: NSView, band: NSRect, near ink: NSColor, tolerance: CGFloat = 0.2
) -> NSColor? {
    guard let reference = ink.usingColorSpace(.sRGB) else { return nil }
    let area = mxBand(band, host: host, bitmap: bitmap)
    guard area.x1 > area.x0, area.y1 > area.y0 else { return nil }
    var best: NSColor?
    var bestDistance = CGFloat.greatestFiniteMagnitude
    for y in area.y0..<area.y1 {
        for x in area.x0..<area.x1 {
            guard let rgb = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let distance =
                abs(rgb.redComponent - reference.redComponent) + abs(rgb.greenComponent - reference.greenComponent)
                + abs(rgb.blueComponent - reference.blueComponent)
            if distance < bestDistance {
                bestDistance = distance
                best = rgb
            }
        }
    }
    return bestDistance <= tolerance ? best : nil
}

// MARK: - Menu tracking

@MainActor
final class MatrixMenuObservation: NSObject {
    private(set) var menu: NSMenu?
    private var tracking: NSMenu?
    private var timer: Timer?
    private let deadline = ProcessInfo.processInfo.systemUptime + 4

    func start() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(began(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self)
    }

    /// Close the tracking loop without choosing an item, exactly like Escape.
    func cancel() {
        menu?.cancelTracking()
        tracking?.cancelTracking()
    }

    @objc private func began(_ notification: Notification) {
        guard let candidate = notification.object as? NSMenu, !candidate.items.isEmpty else { return }
        tracking = candidate
        menu = candidate
    }

    @objc private func tick() {
        if menu != nil || ProcessInfo.processInfo.systemUptime >= deadline {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Suspend on the main actor so the native tracking loop keeps running; never block it.
    func waitForMenu() async -> NSMenu? {
        let limit = ProcessInfo.processInfo.systemUptime + 4
        while menu == nil && ProcessInfo.processInfo.systemUptime < limit {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return menu
    }
}

// MARK: - Fixtures

@MainActor
func mxRequireNil<T>(_ value: T?, _ label: String) throws {
    guard value == nil else { throw MatrixFailure(label: label) }
}

@MainActor
final class MatrixFixture {
    let directory: URL
    let file: PlannerFile
    let store: PlannerStore
    let services: Services
    let model = NotchModel()
    private let priorData: String?

    init() throws {
        try mxRequireNil(Bundle.main.bundleIdentifier, "matrix probe is unbundled")
        priorData = ProcessInfo.processInfo.environment["PERCH_DATA"]
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("matrix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = PlannerFile(url: directory.appendingPathComponent("planner.json"))
        var planner = Planner()
        planner.preferences.welcomeCompleted = true
        planner.preferences.catchCopies = false
        planner.preferences.catchScreenshots = false
        planner.preferences.remindersSync = false
        planner.preferences.resetHour = 0
        try file.save(planner)
        setenv("PERCH_DATA", file.url.path, 1)
        store = PlannerStore(file: file, watching: false)
        services = Services(store: store)
    }

    func close() {
        if let priorData { setenv("PERCH_DATA", priorData, 1) } else { unsetenv("PERCH_DATA") }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Deliberately authored fixture setup, not a production mutation entry point.
    func rewrite(_ body: (inout Planner) -> Void) throws {
        _ = try file.mutate { planner in body(&planner) }
        store.reloadFromDisk(external: false)
    }

    @discardableResult
    func seed(_ titles: [String], day: DayRef) throws -> [PlanTask] {
        guard let created = store.addTasks(titles, on: day, literal: true), created.count == titles.count else {
            throw MatrixFailure(label: "could not seed \(titles)")
        }
        return created
    }
}

@MainActor
func matrixWindow<V: View>(_ view: V, size: NSSize, appearance: NSAppearance? = nil) throws -> (
    NSWindow, NSHostingView<V>
) {
    let host = NSHostingView(rootView: view)
    host.safeAreaRegions = []
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    window.contentView = host
    window.setContentSize(size)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    host.layoutSubtreeIfNeeded()
    return (window, host)
}

@MainActor
final class MatrixFocusDestinations {
    var before = NSTextField(string: "")
    var after = NSTextField(string: "")
}

private struct MatrixDestination: NSViewRepresentable {
    let field: NSTextField
    func makeNSView(context: Context) -> NSTextField { field }
    func updateNSView(_ view: NSTextField, context: Context) {}
}

/// Real text fields make both ends of a key-view loop reachable, exactly as the workspace
/// probe does: native Tab traversal needs a real starting responder.
struct MatrixHarness<Content: View>: View {
    let destinations: MatrixFocusDestinations
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 6) {
            MatrixDestination(field: destinations.before).frame(height: 18)
            content
            MatrixDestination(field: destinations.after).frame(height: 18)
        }
        .padding(8)
        .background(Color.black)
    }
}

// MARK: - Probe

@MainActor
final class AllPageMatrix {
    let report = MatrixReport()
    let output: URL

    init(output: URL) { self.output = output }

    func run() async {
        await report.group("settings panes") { [self] in try await settingsPanes() }
        await report.group("settings failure paths") { [self] in try await settingsFailurePaths() }
        await report.group("dashboard tabs") { [self] in try await dashboardTabs() }
        await report.group("dashboard task and project actions") { [self] in try await dashboardActions() }
        await report.group("welcome states") { [self] in try await welcomeStates() }
        await report.group("details historical and error states") { [self] in try await detailsStates() }
        await report.group("week keyboard") { [self] in try await weekKeyboard() }
        await report.group("clips keyboard") { [self] in try await clipsKeyboard() }
        await report.group("effective enlarged type") { [self] in try await enlargedType() }
        await report.group("effective contrast states") { [self] in try await contrastStates() }
        report.finish(output: output)
    }

    func writeAX(_ root: NSObject, _ url: URL) throws {
        let rows: [[String: Any]] = mxNodes(root).compactMap { node in
            guard let role = mxRole(node) else { return nil }
            return [
                "role": role, "id": mxIdentifier(node) ?? "", "label": mxLabel(node) ?? "",
                "frame": NSStringFromRect(mxFrame(node)),
                "enabled": (try? mxBool(node, "isAccessibilityEnabled")) ?? false,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    // MARK: Settings: five panes

    func settingsPanes() async throws {
        let fixture = try MatrixFixture()
        defer { fixture.close() }
        let view = SettingsView().environmentObject(fixture.store).environmentObject(fixture.services)
            .environment(\.colorScheme, .dark)
        let (window, host) = try matrixWindow(view, size: NSSize(width: 760, height: 640))
        defer { window.close() }
        await mxSettle(1.0)

        // Two markers per pane that exist nowhere else in Settings, and never collide with the
        // sidebar row titles ("General", "Workspace", "Focus timer", "AI agents", "System").
        let markers: [(SettingsView.Pane, String, String)] = [
            (.general, "Opening", "Apple Intelligence"),
            (.workspace, "Beside today's tasks", "Calendar"),
            (.focus, "Default length", "Workspace timer face"),
            (.agents, "Connect AI agents", "Or use Terminal"),
            (.system, "Your data", "Apple Reminders"),
        ]
        var observed: [String: Int] = [:]
        for (pane, marker, second) in markers {
            try selectPane(pane, window: window, host: host, root: host)
            await mxSettle(0.7)
            let texts = mxText(host)
            try report.require(
                texts.contains(AppL10n.text(marker)), "settings \(pane.rawValue) pane shows \(marker)",
                "present \(texts.prefix(14))")
            try report.require(
                texts.contains(AppL10n.text(second)), "settings \(pane.rawValue) pane shows \(second)",
                "present \(texts.prefix(14))")
            observed[pane.rawValue] = texts.count
            try mxSave(host, output.appendingPathComponent("settings-\(pane.rawValue.lowercased()).png"))
            try writeAX(host, output.appendingPathComponent("settings-\(pane.rawValue.lowercased()).ax.json"))
        }
        // Selecting System must retire the General detail: the sidebar really drives the pane.
        try report.require(
            !mxHas(host, AppL10n.text("Apple Intelligence")),
            "settings detail is replaced when the pane changes")
        report.record("settingsPaneNodeCounts", observed)
    }

    func selectPane(_ pane: SettingsView.Pane, window: NSWindow, host: NSView, root: NSObject) throws {
        let title = pane.title
        let rows = mxNodes(root).filter { (mxRole($0) ?? "").contains("Row") }
        for row in rows {
            let labels = mxText(row)
            guard mxLabel(row) == title || labels.contains(title) else { continue }
            mxClick(host: host, window: window, at: mxHostRect(row, window: window, host: host))
            return
        }
        throw MatrixFailure(label: "no settings sidebar row for \(title) (\(rows.count) rows)")
    }

    // MARK: Settings: a synthetic failure path per pane

    func settingsFailurePaths() async throws {
        let fixture = try MatrixFixture()
        defer { fixture.close() }
        let view = SettingsView().environmentObject(fixture.store).environmentObject(fixture.services)
            .environment(\.colorScheme, .dark)
        let (window, host) = try matrixWindow(view, size: NSSize(width: 760, height: 640))
        defer { window.close() }
        await mxSettle(1.0)

        // General: the Apple Intelligence control must present the real availability reason and
        // follow the real availability; nothing may touch the login item.
        try selectPane(.general, window: window, host: host, root: host)
        await mxSettle(0.7)
        let loginStatus = SMAppService.mainApp.status
        let expectedExplanation = SettingsView.appleIntelligenceExplanation(
            isSupported: AISorter.isSupported, unavailableReason: AISorter.unavailableReason)
        try report.require(
            mxHas(host, AppL10n.text("Auto-sort new tasks")),
            "general pane exposes the auto-sort control", "texts \(mxText(host).prefix(14))")
        try report.require(
            mxHas(host, expectedExplanation),
            "general pane explains the AI failure state", "isSupported=\(AISorter.isSupported)")
        if let aiCheckbox = mxFind(host, label: AppL10n.text("Auto-sort new tasks")) {
            let enabled = try mxBool(aiCheckbox, "isAccessibilityEnabled")
            try report.require(
                enabled == AISorter.isSupported, "auto-sort enablement follows real AI availability",
                "enabled=\(enabled) supported=\(AISorter.isSupported)")
        } else {
            try report.require(false, "general pane exposes the auto-sort checkbox")
        }
        try report.require(
            SMAppService.mainApp.status == loginStatus, "general pane never mutates the login item")

        // Workspace: the calendar row must report the state the system actually holds, and
        // reading it must not request access.
        let calendarBefore = EKEventStore.authorizationStatus(for: .event)
        let calendarState = SettingsPermissionAccess.eventState(calendarBefore).state
        try selectPane(.workspace, window: window, host: host, root: host)
        await mxSettle(1.0)
        try report.require(
            mxHas(host, calendarState.title), "workspace pane reports the real calendar permission state",
            "expected \(calendarState.title)")
        try report.require(
            EKEventStore.authorizationStatus(for: .event) == calendarBefore,
            "workspace pane never requests calendar access")
        try report.require(
            calendarState == .allowed || !fixture.services.calendar.hasAccess,
            "workspace pane calendar access matches the reported state")

        // Focus: a corrupted persisted length must be surfaced, not silently rewritten.
        try fixture.rewrite { $0.preferences.defaultFocusMinutes = 0 }
        try selectPane(.focus, window: window, host: host, root: host)
        await mxSettle(0.7)
        try report.require(
            mxHas(host, AppL10n.format("%lld min", 0)), "focus pane surfaces the out-of-range length",
            "texts \(mxText(host).prefix(16))")
        try report.require(
            (try fixture.file.load()).preferences.defaultFocusMinutes == 0,
            "focus pane does not silently repair the persisted length")

        // Agents: an unbundled probe cannot install agents, so the warning must be shown and no
        // connector may change state.
        let agentStatuses = AgentConnector.App.allCases.map { AgentConnector.status($0) }
        try selectPane(.agents, window: window, host: host, root: host)
        await mxSettle(0.7)
        try report.require(!AppInfo.isInApplications, "matrix probe is not installed in Applications")
        try report.require(
            mxHas(host, "Agent setup requires Perch to be installed in Applications."),
            "agents pane shows the not-installed failure path", "texts \(mxText(host).prefix(16))")
        try report.require(
            AgentConnector.App.allCases.map { AgentConnector.status($0) } == agentStatuses,
            "agents pane never mutates a connector")

        // System: the reminders row must report the real state, the dependent phone alert must be
        // disabled while mirroring is off, and no sync may run.
        let reminderBefore = EKEventStore.authorizationStatus(for: .reminder)
        let reminderState = SettingsPermissionAccess.eventState(reminderBefore).state
        let tasksBefore = fixture.store.planner.tasks.count
        try selectPane(.system, window: window, host: host, root: host)
        await mxSettle(1.0)
        try report.require(
            mxHas(host, reminderState.title), "system pane reports the real reminders permission state",
            "expected \(reminderState.title)")
        if let phoneToggle = mxFind(host, label: AppL10n.text("Alert on iPhone and Apple Watch too")) {
            try report.require(
                try mxBool(phoneToggle, "isAccessibilityEnabled") == fixture.store.prefs.remindersSync,
                "phone alert stays disabled while mirroring is off")
        } else {
            try report.require(false, "system pane exposes the phone alert control")
        }
        try report.require(
            EKEventStore.authorizationStatus(for: .reminder) == reminderBefore,
            "system pane never requests reminders access")
        try report.require(
            fixture.store.planner.tasks.count == tasksBefore, "system pane never mutates the planner")
        try mxSave(host, output.appendingPathComponent("settings-system.png"))
    }

    // MARK: Dashboard: four tabs

    func dashboardTabs() async throws {
        let fixture = try MatrixFixture()
        defer { fixture.close() }
        try fixture.seed(["Matrix upcoming task"], day: .day(fixture.store.today.adding(days: 1)))
        try fixture.seed(["Matrix history task"], day: .day(fixture.store.today.adding(days: -1)))
        try fixture.seed(["Matrix today task"], day: .day(fixture.store.today))

        let destinations = MatrixFocusDestinations()
        let view = MatrixHarness(destinations: destinations) {
            DashboardView(tab: .upcoming)
                .environmentObject(fixture.store)
                .environment(\.accessibilityEnabled, true)
                .frame(width: 880, height: 560)
        }
        let (window, host) = try matrixWindow(view, size: NSSize(width: 900, height: 620))
        defer { window.close() }
        await mxSettle(1.0)
        try report.require(window.makeFirstResponder(destinations.before), "dashboard fixture starts from a field")

        // One keyboard-reachability assertion for the tab group itself.
        var traversal: [String] = []
        var reached = false
        for _ in 0..<16 {
            try await mxKey(window, 48, "\t")
            traversal.append(mxFocusIdentity(window) ?? "none")
            if mxFocusedRole(window) == "AXRadioButton" {
                reached = true
                break
            }
        }
        report.record("dashboardTabTraversal", traversal)
        try report.require(reached, "Tab reaches the dashboard tab controls", "traversal \(traversal)")

        // Every tab is exercised through the real segmented control.
        let markers: [(DashboardView.Tab, String, String)] = [
            (.upcoming, "Matrix upcoming task", "Matrix history task"),
            (.history, "Matrix history task", "Matrix upcoming task"),
            (.insights, AppL10n.text("Streak"), "Matrix history task"),
            (.projects, AppL10n.text("No projects yet. Add #project to a new task."), "Matrix history task"),
        ]
        for (tab, marker, foreign) in markers {
            let radio = mxNodes(host).filter {
                mxRole($0) == "AXRadioButton" && mxLabel($0) == AppL10n.text(tab.rawValue)
            }
            guard let segment = radio.first else {
                throw MatrixFailure(label: "no dashboard segment for \(tab.rawValue)")
            }
            mxClick(host: host, window: window, at: mxHostRect(segment, window: window, host: host))
            await mxSettle(0.7)
            let texts = mxText(host)
            try report.require(
                texts.contains(marker) || mxHasContaining(host, marker),
                "dashboard \(tab.rawValue) tab renders its own content", "present \(texts.prefix(10))")
            try report.require(
                !texts.contains(foreign), "dashboard \(tab.rawValue) tab retires the other panes",
                "leaked \(foreign)")
        }
        try mxSave(host, output.appendingPathComponent("dashboard-tabs.png"))
    }

    func mxFocusedRole(_ window: NSWindow) -> String? {
        guard let node = mxFocusedNode(window) else { return nil }
        return mxRole(node)
    }

    // MARK: Dashboard: task-line and project actions from real key events

    func dashboardActions() async throws {
        let fixture = try MatrixFixture()
        defer { fixture.close() }
        guard fixture.store.addTasks(["Matrix project task #Matrix"], on: .day(fixture.store.today)) != nil,
            let project = fixture.store.planner.projects.first
        else { throw MatrixFailure(label: "could not seed a project through the parser") }
        try fixture.seed(["Matrix history alpha"], day: .day(fixture.store.today.adding(days: -1)))
        try fixture.seed(["Matrix history beta"], day: .day(fixture.store.today.adding(days: -1)))

        let destinations = MatrixFocusDestinations()
        let projectView = MatrixHarness(destinations: destinations) {
            DashboardView(tab: .projects)
                .environmentObject(fixture.store)
                .environment(\.accessibilityEnabled, true)
                .frame(width: 880, height: 560)
        }
        let (window, _) = try matrixWindow(projectView, size: NSSize(width: 900, height: 620))
        defer { window.close() }
        await mxSettle(1.0)
        try report.require(window.makeFirstResponder(destinations.before), "project fixture starts from a field")

        let deleteLabel = AppL10n.text("Delete project")
        var traversal: [String] = []
        var reached = false
        for _ in 0..<24 {
            try await mxKey(window, 48, "\t")
            traversal.append(mxFocusIdentity(window) ?? "none")
            if mxFocusIdentity(window) == deleteLabel {
                reached = true
                break
            }
        }
        report.record("projectActionTraversal", traversal)
        try report.require(reached, "Tab reaches the delete-project action", "traversal \(traversal)")
        let taskCount = fixture.store.planner.tasks.count
        try await mxKey(window, 49, " ")
        await mxSettle(0.7)
        try report.require(
            !fixture.store.planner.projects.contains { $0.id == project.id },
            "Space on the project action deletes that project")
        try report.require(
            fixture.store.planner.tasks.count == taskCount, "deleting a project keeps its tasks",
            "tasks \(fixture.store.planner.tasks.count) vs \(taskCount)")

        // Task lines answer real typed keys in the History tab.
        let historyView = MatrixHarness(destinations: destinations) {
            DashboardView(tab: .history)
                .environmentObject(fixture.store)
                .environment(\.accessibilityEnabled, true)
                .frame(width: 880, height: 560)
        }
        let (historyWindow, historyHost) = try matrixWindow(historyView, size: NSSize(width: 900, height: 620))
        defer { historyWindow.close() }
        await mxSettle(1.0)
        try report.require(
            historyWindow.makeFirstResponder(destinations.before), "history fixture starts from a field")
        var searchTraversal: [String] = []
        var focused = false
        for _ in 0..<16 {
            try await mxKey(historyWindow, 48, "\t")
            searchTraversal.append(mxFocusIdentity(historyWindow) ?? "none")
            if mxFocusedRole(historyWindow) == "AXTextField" {
                focused = true
                break
            }
        }
        report.record("historySearchTraversal", searchTraversal)
        try report.require(focused, "Tab reaches the history search field", "traversal \(searchTraversal)")
        let before = mxStaticTexts(historyHost).filter { $0.contains("Matrix history") }.count
        try report.require(before == 2, "history lists both seeded task lines", "count \(before)")
        for character in "Matrix history alpha".map(String.init) {
            let scalar = character.unicodeScalars.first?.value ?? 0
            try await mxKey(
                historyWindow, 0, character, modifiers: scalar >= 65 && scalar <= 90 ? .shift : [])
        }
        await mxSettle(0.9)
        let typed = mxFocusedNode(historyWindow).flatMap { mxAttribute($0, "accessibilityValue") as? String }
        try report.require(
            typed == "Matrix history alpha", "typed keys land in the history search field", "value \(typed ?? "none")")
        let after = mxStaticTexts(historyHost).filter { $0.contains("Matrix history") }.count
        try report.require(after == 1, "typed search filters the task lines", "count \(after)")
        try mxSave(historyHost, output.appendingPathComponent("dashboard-history-search.png"))
    }

    // MARK: Welcome

    func welcomeStates() async throws {
        let fixture = try MatrixFixture()
        defer { fixture.close() }
        var opened = 0
        let view = WelcomeView(done: { opened += 1 })
            .environmentObject(fixture.store).environmentObject(fixture.services)
            .environment(\.colorScheme, .dark)
        let (window, host) = try matrixWindow(view, size: NSSize(width: 560, height: 900))
        defer { window.close() }
        await mxSettle(1.4)

        try report.require(
            mxHas(host, AppL10n.text("Your plan, close at hand.")), "welcome renders its heading")
        // Every permission row must show the state the system actually holds: with no grant, the
        // failure state is what the user sees, and the CTA must still work.
        var states: [String: String] = [:]
        let access = SettingsPermissionAccess(services: fixture.services)
        for feature in PermissionFeature.allCases {
            let reading = await access.read(feature)
            states[feature.rawValue] = reading.state.rawValue
            try report.require(
                mxHas(host, reading.state.title), "welcome shows \(feature.rawValue) as \(reading.state.title)",
                "texts \(mxText(host).prefix(24))")
        }
        report.record("welcomePermissionStates", states)
        let allowedRows = mxText(host).filter { $0 == PermissionState.allowed.title }.count
        let allowedStates = states.values.filter { $0 == PermissionState.allowed.rawValue }.count
        try report.require(
            allowedRows == allowedStates, "welcome never claims access the system did not grant",
            "rows \(allowedRows) states \(allowedStates)")

        // A keybinding registration failure is a real error surface: the view must re-read and
        // keep rendering instead of dropping the shortcut line.
        NotificationCenter.default.post(name: ShortcutStore.didFail, object: nil)
        await mxSettle(0.6)
        let display = ShortcutStore.load().display
        try report.require(
            mxHasContaining(host, display), "welcome keeps the shortcut line after a registration failure",
            "display \(display)")
        try report.require(
            mxHas(host, AppL10n.text("Skip any permission. You can review it later in Settings.")),
            "welcome keeps the skip promise in the failure state")

        guard let cta = mxFind(host, label: AppL10n.text("Open workspace")) else {
            throw MatrixFailure(label: "welcome has no Open workspace action")
        }
        try mxPress(cta)
        await mxSettle(0.5)
        try report.require(opened == 1, "welcome opens the workspace without any permission")
        try mxSave(host, output.appendingPathComponent("welcome-failure-state.png"))
    }

    // MARK: Details: historical and error states

    func detailsStates() async throws {
        let fixture = try MatrixFixture()
        defer { fixture.close() }
        let past = try fixture.seed(["Matrix past task"], day: .day(fixture.store.today.adding(days: -1))).first
        try fixture.seed(["Matrix today task"], day: .day(fixture.store.today))
        guard let past else { throw MatrixFailure(label: "could not seed the historical task") }
        let (window, host) = try matrixWindow(workspaceFixture(fixture), size: NSSize(width: 880, height: 520))
        defer { window.close() }
        await mxSettle(1.1)

        // Historical task: a read-only sheet, never an editable one.
        fixture.model.detailsTaskID = past.id
        await mxSettle(1.4)
        guard let sheet = window.attachedSheet else {
            throw MatrixFailure(label: "details sheet did not attach for a past task")
        }
        try report.require(
            mxHas(sheet, AppL10n.text("Earlier days are read-only. Your history and focus time stay unchanged.")),
            "details sheet shows the historical read-only state", "texts \(mxText(sheet).prefix(16))")
        try report.require(
            mxNodes(sheet).allSatisfy { mxIdentifier($0) != "details-title" },
            "historical details expose no editable title field")
        if let save = mxNodes(sheet).first(where: { mxIdentifier($0) == "details-save" }) {
            try report.require(
                try mxBool(save, "isAccessibilityEnabled") == false, "historical details cannot save")
        } else {
            try report.require(false, "historical details expose the save control")
        }
        try await mxKey(sheet, 53, "\u{1b}")
        await mxSettle(1.2)
        try report.require(window.attachedSheet == nil, "Escape dismisses the historical details sheet")
        try report.require(
            fixture.store.planner.tasks.contains { $0.id == past.id && $0.title == "Matrix past task" },
            "dismissing historical details leaves the task unchanged")
        try report.require(window.isKeyWindow, "workspace keeps the key window after dismiss")
        // Keyboard focus must be usable in the workspace again, not stranded on a dead sheet.
        try await mxKey(window, 48, "\t")
        if let focused = mxFocusedNode(window) {
            try report.require(
                mxNodes(host).contains { $0 === focused }, "focus returns into the workspace after dismiss",
                "focused \(mxRole(focused) ?? "unknown")")
        } else {
            try report.require(false, "focus returns into the workspace after dismiss")
        }

        // Removed task: the error state, not a blank sheet.
        fixture.model.detailsTaskID = UUID()
        await mxSettle(1.4)
        guard let errorSheet = window.attachedSheet else {
            throw MatrixFailure(label: "details sheet did not attach for a removed task")
        }
        try report.require(
            mxHas(errorSheet, AppL10n.text("Task unavailable")), "removed task shows the unavailable state",
            "texts \(mxText(errorSheet).prefix(14))")
        try report.require(
            mxHas(errorSheet, AppL10n.text("This task was removed.")), "removed task explains what happened")
        try report.require(
            mxNodes(errorSheet).contains { mxIdentifier($0) == "details-close" },
            "removed task offers an explicit close control")
        try mxSave(host, output.appendingPathComponent("details-error-state.png"))
        try await mxKey(errorSheet, 53, "\u{1b}")
        await mxSettle(1.2)
        try report.require(window.attachedSheet == nil, "Escape dismisses the removed-task sheet")
        try report.require(
            fixture.store.planner.tasks.count == 2, "no task is created or removed by the error state")
    }

    func workspaceFixture(_ fixture: MatrixFixture) -> some View {
        MatrixHarness(destinations: MatrixFocusDestinations()) {
            WorkspaceView(notchHeight: 32)
                .environmentObject(fixture.store)
                .environmentObject(fixture.services)
                .environmentObject(fixture.model)
                .environment(\.colorScheme, .dark)
                .frame(width: 820, height: 420)
        }
    }

    // MARK: Week: real key events, nested Escape, focus return

    func weekKeyboard() async throws {
        let fixture = try MatrixFixture()
        defer { fixture.close() }
        guard let task = try fixture.seed(["Matrix week task"], day: .day(fixture.store.today)).first else {
            throw MatrixFailure(label: "could not seed the week task")
        }
        let destinations = MatrixFocusDestinations()
        let view = MatrixHarness(destinations: destinations) {
            WorkspaceView(notchHeight: 32)
                .environmentObject(fixture.store)
                .environmentObject(fixture.services)
                .environmentObject(fixture.model)
                .environment(\.colorScheme, .dark)
                .frame(width: 820, height: 420)
        }
        let (window, host) = try matrixWindow(view, size: NSSize(width: 880, height: 520))
        defer { window.close() }
        await mxSettle(1.1)
        try report.require(window.makeFirstResponder(destinations.before), "week fixture starts from a field")

        // The Inbox toggle is a real keyboard action with a visible consequence.
        let inboxTitle = AppL10n.format("Inbox (%lld)", fixture.store.engine.tasks(on: .inbox).count)
        var traversal: [String] = []
        var reached = false
        for _ in 0..<24 {
            try await mxKey(window, 48, "\t")
            traversal.append(mxFocusIdentity(window) ?? "none")
            if mxFocusIdentity(window) == "week-inbox" {
                reached = true
                break
            }
        }
        report.record("weekKeyboardTraversal", traversal)
        try report.require(reached, "Tab reaches the Inbox toggle", "traversal \(traversal)")
        try report.require(mxHas(host, inboxTitle), "week header shows the Inbox count", "expected \(inboxTitle)")
        try await mxKey(window, 49, " ")
        await mxSettle(0.8)
        try report.require(
            mxHas(host, AppL10n.text("Back to week")), "Space on the Inbox toggle swaps the week for the Inbox",
            "texts \(mxText(host).prefix(14))")
        try await mxKey(window, 49, " ")
        await mxSettle(0.8)
        try report.require(mxHas(host, inboxTitle), "Space returns to the week view")

        // The task-line menu: a real key press opens a real native menu, Escape closes it, and
        // focus returns to the control that opened it.
        let menuID = "week-menu-\(task.id)"
        var menuTraversal: [String] = []
        var menuFocused = false
        for _ in 0..<32 {
            try await mxKey(window, 48, "\t")
            menuTraversal.append(mxFocusIdentity(window) ?? "none")
            if mxFocusIdentity(window) == menuID {
                menuFocused = true
                break
            }
        }
        report.record("weekMenuTraversal", menuTraversal)
        try report.require(menuFocused, "Tab reaches the task-line actions menu", "traversal \(menuTraversal)")
        let tasksBefore = fixture.store.planner.tasks.map { "\($0.id)-\($0.title)-\($0.done)" }

        let observation = MatrixMenuObservation()
        observation.start()
        defer { observation.stop() }
        try await mxKey(window, 49, " ")
        guard let menu = await observation.waitForMenu() else {
            throw MatrixFailure(label: "Space did not open the task-line menu")
        }
        let titles = menu.items.map { $0.title }
        try report.require(
            titles.contains(AppL10n.text("Details…")), "task-line menu opens with Details", "items \(titles)")
        try report.require(
            titles.contains(AppL10n.text("Move to day")), "task-line menu opens with Move to day")
        try report.require(
            menu.items.contains { $0.title == AppL10n.text("Delete") && $0.isEnabled },
            "task-line menu opens with an enabled Delete")
        try await mxKey(window, 53, "\u{1b}")
        observation.cancel()
        await mxSettle(0.7)
        try mxAssertFocused(window, menuID, "Escape returns focus to the task-line menu control", report: report)
        try report.require(
            fixture.store.planner.tasks.map { "\($0.id)-\($0.title)-\($0.done)" } == tasksBefore,
            "opening and cancelling the menu never mutates the task")

        // Nested Escape: the task line opens a sheet over the page; Escape dismisses it and the
        // task line stays intact with keyboard focus usable again.
        fixture.model.detailsTaskID = task.id
        await mxSettle(1.4)
        guard let sheet = window.attachedSheet else {
            throw MatrixFailure(label: "week details sheet did not attach")
        }
        try report.require(
            mxHas(sheet, AppL10n.text("Task details")), "week details sheet shows the editable state",
            "texts \(mxText(sheet).prefix(14))")
        try await mxKey(sheet, 53, "\u{1b}")
        await mxSettle(1.2)
        try report.require(window.attachedSheet == nil, "nested Escape dismisses the details sheet")
        try report.require(window.isKeyWindow, "week panel returns to key after the sheet closes")
        try report.require(
            fixture.store.planner.tasks.map { "\($0.id)-\($0.title)-\($0.done)" } == tasksBefore,
            "cancelling the sheet never mutates the task")
        try mxSave(host, output.appendingPathComponent("week-keyboard.png"))
    }

    // MARK: Clips: real key events, menu Escape, focus return

    func clipsKeyboard() async throws {
        let fixture = try MatrixFixture()
        defer { fixture.close() }
        let pasteboard = MatrixPasteboard()
        let clips = ClipsService(store: fixture.store, pasteboard: pasteboard, monitoring: false)
        clips.add(.text("Matrix clip one"), source: "dropped")
        clips.add(.text("Matrix clip two"), source: "dropped")
        try report.require(clips.clips.count == 2, "clips fixture keeps two clips")
        guard let first = clips.clips.first else { throw MatrixFailure(label: "clips fixture lost its clips") }
        let realChangeCount = NSPasteboard.general.changeCount
        let destinations = MatrixFocusDestinations()
        let view = MatrixHarness(destinations: destinations) {
            ClipsBody(clips: clips)
                .environmentObject(fixture.store)
                .environment(\.accessibilityEnabled, true)
                .environment(\.colorScheme, .dark)
                .frame(width: 820, height: 360)
        }
        let (window, host) = try matrixWindow(view, size: NSSize(width: 880, height: 440))
        defer { window.close() }
        await mxSettle(1.1)
        try report.require(window.makeFirstResponder(destinations.before), "clips fixture starts from a field")

        // Keyboard copy: Space on the focused copy control, into the recording pasteboard.
        let copyLabel = AppL10n.format("Copy %@", first.title)
        var traversal: [String] = []
        var reached = false
        for _ in 0..<24 {
            try await mxKey(window, 48, "\t")
            traversal.append(mxFocusIdentity(window) ?? "none")
            if mxFocusIdentity(window) == copyLabel {
                reached = true
                break
            }
        }
        report.record("clipsCopyTraversal", traversal)
        try report.require(reached, "Tab reaches the clip copy control", "traversal \(traversal)")
        try await mxKey(window, 49, " ")
        await mxSettle(0.6)
        try report.require(
            pasteboard.writes.count == 1, "Space copies the clip once", "writes \(pasteboard.writes.count)")
        if case .text(let value)? = pasteboard.writes.first {
            try report.require(value == "Matrix clip one", "the keyboard copy carries the clip text", "value \(value)")
        } else {
            try report.require(false, "the keyboard copy carries the clip text", "writes \(pasteboard.writes.count)")
        }
        try report.require(
            NSPasteboard.general.changeCount == realChangeCount, "keyboard copy never touches the real clipboard")
        try report.require(clips.clips.count == 2, "keyboard copy never edits the clip list")

        // Actions menu: real key presses open and cancel a real NSMenu, and focus comes back.
        let actionsID = "clips.actions.\(first.id)"
        var menuTraversal: [String] = []
        var menuReached = false
        for _ in 0..<24 {
            try await mxKey(window, 48, "\t")
            menuTraversal.append(mxFocusIdentity(window) ?? "none")
            if mxFocusIdentity(window) == actionsID {
                menuReached = true
                break
            }
        }
        report.record("clipsMenuTraversal", menuTraversal)
        try report.require(menuReached, "Tab reaches the clip actions menu", "traversal \(menuTraversal)")
        let pinnedBefore = clips.clips.map { $0.pinned }
        let observation = MatrixMenuObservation()
        observation.start()
        defer { observation.stop() }
        try await mxKey(window, 49, " ")
        guard let menu = await observation.waitForMenu() else {
            throw MatrixFailure(label: "Space did not open the clip actions menu")
        }
        let titles = menu.items.map { $0.title }
        try report.require(titles.contains(AppL10n.text("Pin")), "clip actions menu opens with Pin", "items \(titles)")
        try report.require(titles.contains(AppL10n.text("Remove")), "clip actions menu opens with Remove")
        try await mxKey(window, 53, "\u{1b}")
        observation.cancel()
        await mxSettle(0.7)
        try mxAssertFocused(window, actionsID, "Escape returns focus to the clip actions menu", report: report)
        try report.require(clips.clips.map { $0.pinned } == pinnedBefore, "opening and cancelling never pins a clip")
        try mxSave(host, output.appendingPathComponent("clips-keyboard.png"))
    }

    // MARK: Effective enlarged type, measured on pixels and AX frames

    func enlargedType() async throws {
        let fixture = try MatrixFixture()
        defer { fixture.close() }
        var measurements: [String: Any] = [:]
        // The status label paints Theme.warning in the dark palette; measure that opaque ink
        // rather than a dynamic colour resolved against the process appearance.
        let warningInk = mxTokenColor(ThemeTokens.dark.warning)
        for (name, size) in [("large", DynamicTypeSize.large), ("accessibility3", DynamicTypeSize.accessibility3)] {
            let view = VStack(alignment: .leading, spacing: 10) {
                PermissionPanel(services: fixture.services, features: [.notifications])
                Text("Matrix fixed control")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(nsColor: warningInk))
                    .accessibilityIdentifier("matrix-fixed-label")
            }
            .padding(12)
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .dark)
            .frame(width: 420, height: 200)
            let (window, host) = try matrixWindow(view, size: NSSize(width: 440, height: 230))
            await mxSettle(1.2)
            let statusTitle = PermissionState.unavailable.title
            guard let status = mxFind(host, label: statusTitle) else {
                window.close()
                throw MatrixFailure(label: "no \(statusTitle) status label at \(name)")
            }
            let frame = mxHostRect(status, window: window, host: host)
            let bitmap = try mxBitmap(host)
            let rows = mxInkRows(bitmap, host: host, band: frame, ink: warningInk)
            let fixedFrame = mxHostRect(try mxIdentified(host, "matrix-fixed-label"), window: window, host: host)
            let fixedRows = mxInkRows(bitmap, host: host, band: fixedFrame, ink: warningInk)
            try mxSave(host, output.appendingPathComponent("enlarged-\(name).png"))
            measurements[name] = [
                "status_frame": NSStringFromRect(frame), "status_ink_rows": rows.count,
                "fixed_frame": NSStringFromRect(fixedFrame), "fixed_ink_rows": fixedRows.count,
            ]
            report.record("enlarged_\(name)", measurements[name] ?? [String: Any]())
            window.close()
        }
        guard let large = measurements["large"] as? [String: Any],
            let big = measurements["accessibility3"] as? [String: Any],
            let largeFrame = (large["status_frame"] as? String).map(NSRectFromString),
            let bigFrame = (big["status_frame"] as? String).map(NSRectFromString),
            let largeRows = large["status_ink_rows"] as? Int,
            let bigRows = big["status_ink_rows"] as? Int,
            let largeFixed = large["fixed_ink_rows"] as? Int,
            let bigFixed = big["fixed_ink_rows"] as? Int
        else { throw MatrixFailure(label: "enlarged-type measurements incomplete") }
        try report.require(
            bigFrame.height >= largeFrame.height * 1.5,
            "enlarged type grows the real AX frame of a rendered status label",
            "large \(largeFrame.height) to \(bigFrame.height)")
        try report.require(
            bigRows >= largeRows * 2, "enlarged type grows the rendered ink rows of that label",
            "large \(largeRows) to \(bigRows)")
        // Negative control: a fixed 11pt control in the same host must not grow, so the
        // measurement cannot pass merely because the whole render scaled.
        try report.require(
            abs(bigFixed - largeFixed) <= 1, "negative control: a fixed-size control does not grow",
            "large \(largeFixed) to \(bigFixed)")
        try report.require(
            bigRows > bigFixed, "the measured label is the scaled one, not the fixed control",
            "status \(bigRows) fixed \(bigFixed)")
    }

    // MARK: Effective contrast states, measured on rendered pixels

    func contrastStates() async throws {
        let fixture = try MatrixFixture()
        defer { fixture.close() }
        var rows: [[String: Any]] = []
        for (mode, appearanceName, scheme, bodyInk, lowInk) in [
            (
                "dark-increased", NSAppearance.Name.accessibilityHighContrastDarkAqua, ColorScheme.dark,
                mxTokenColor(ThemeTokens.dark.secondary), NSColor(white: 0.32, alpha: 1)
            ),
            (
                "light-increased", NSAppearance.Name.accessibilityHighContrastAqua, ColorScheme.light,
                mxTokenColor(ThemeTokens.light.secondary), NSColor(white: 0.72, alpha: 1)
            ),
        ] {
            guard let appearance = NSAppearance(named: appearanceName) else {
                throw MatrixFailure(label: "missing appearance \(appearanceName.rawValue)")
            }
            let view = VStack(alignment: .leading, spacing: 10) {
                PermissionPanel(services: fixture.services, features: [.notifications])
                Text("Matrix low contrast control")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(nsColor: lowInk))
                    .accessibilityIdentifier("matrix-low-contrast")
            }
            .padding(12)
            .environment(\.colorScheme, scheme)
            .frame(width: 420, height: 190)
            let (window, host) = try matrixWindow(view, size: NSSize(width: 440, height: 220), appearance: appearance)
            await mxSettle(1.2)
            let effective = window.effectiveAppearance.name.rawValue
            try report.require(
                effective == appearanceName.rawValue, "\(mode) window runs in the increased-contrast appearance",
                "effective \(effective)")
            let detail = AppL10n.text(
                "Allow reminder and timer alerts. Delivery also depends on macOS notification and Focus settings.")
            guard let detailNode = mxFind(host, label: detail) else {
                window.close()
                throw MatrixFailure(label: "no permission detail text at \(mode)")
            }
            let bitmap = try mxBitmap(host)
            let detailRect = mxHostRect(detailNode, window: window, host: host)
            guard let background = mxDominant(bitmap, host: host, band: detailRect),
                let ink = mxInkSample(bitmap, host: host, band: detailRect, near: bodyInk)
            else {
                window.close()
                throw MatrixFailure(label: "could not sample rendered text at \(mode)")
            }
            let ratio = mxContrast(ink, background)
            try report.require(
                ratio >= 4.5, "\(mode) renders body text above 4.5:1",
                "measured \(String(format: "%.2f", ratio))")

            // Negative control: the same measurement must flag a genuinely low-contrast label.
            let lowRect = mxHostRect(try mxIdentified(host, "matrix-low-contrast"), window: window, host: host)
            if let lowBackground = mxDominant(bitmap, host: host, band: lowRect),
                let lowSample = mxInkSample(bitmap, host: host, band: lowRect, near: lowInk)
            {
                let lowRatio = mxContrast(lowSample, lowBackground)
                try report.require(
                    lowRatio < 4.5, "\(mode) negative control: a low-contrast label is detected",
                    "measured \(String(format: "%.2f", lowRatio))")
            } else {
                try report.require(false, "\(mode) negative control: a low-contrast label is detected")
            }
            rows.append([
                "mode": mode, "effective_appearance": effective, "ratio": ratio,
                "ink": mxHex(ink), "background": mxHex(background),
            ])
            try mxSave(host, output.appendingPathComponent("contrast-\(mode).png"))
            window.close()
        }
        report.record("contrast", rows)
    }

    func mxHex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#000000" }
        return String(
            format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255))
    }
}

// MARK: - Recording pasteboard

@MainActor
final class MatrixPasteboard: PasteboardAccess {
    private(set) var writes: [PasteboardValue] = []
    let changeCount = 0
    let declaredTypes: [String] = []
    let fileURLs: [URL] = []
    let imageData: Data? = nil
    let plainText: String? = nil
    func replace(with value: PasteboardValue) { writes.append(value) }
}

// MARK: - Entry point

let matrixApplication = NSApplication.shared
matrixApplication.setActivationPolicy(.accessory)
// Argument-domain override only: the probe never writes the user's keyboard preferences.
var matrixArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
matrixArguments["AppleKeyboardUIMode"] = 3
UserDefaults.standard.setVolatileDomain(matrixArguments, forName: UserDefaults.argumentDomain)

Task { @MainActor in
    let output =
        ProcessInfo.processInfo.environment["MATRIX_OUTPUT"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("allpage-matrix")
    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    await AllPageMatrix(output: output).run()
}
matrixApplication.run()
