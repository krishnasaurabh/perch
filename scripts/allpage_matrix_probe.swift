// CI-only all-page matrix probe. Renders the production Settings, Dashboard, Welcome,
// Workspace (Week), Clips and Details surfaces in real windows and drives them with real
// NSEvent key events, measured accessibility frames read through the system AX API, and
// rendered pixels.
//
// Nothing here mutates the user's world: the planner is a synthetic file in a temporary
// directory, the clipboard is a recording fake, permissions are only ever read, and every
// measurement has a probe-local negative control that proves the measurement can go red.
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

/// Unbuffered, unconditional log line: a killed probe still shows how far it got.
func mxLog(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }

/// Announced once so a trap before the first assertion still says where the process was.
@MainActor
final class MatrixMark {
    nonisolated(unsafe) static var announced = false
    static func firstAccessibilityRead() {
        guard !announced else { return }
        announced = true
        mxLog("matrix probe: first accessibility read")
    }
}

/// The stage name a watchdog reports if the probe ever stops making progress. Nothing here
/// blocks: a hang always names the step that hung instead of burning the job timeout.
@MainActor
final class MatrixStage {
    nonisolated(unsafe) static var current = "start"
    nonisolated(unsafe) static var watchdog: DispatchSourceTimer?

    static func mark(_ stage: String) {
        current = stage
        mxLog("matrix stage: \(stage)")
    }

    static func startWatchdog(seconds: Int = 150) {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + .seconds(seconds))
        timer.setEventHandler {
            FileHandle.standardError.write(
                Data("FAIL: all-page matrix watchdog fired during stage: \(MatrixStage.current)\n".utf8))
            exit(3)
        }
        timer.resume()
        watchdog = timer
    }
}

@MainActor
final class MatrixReport {
    private(set) var passed: [String] = []
    private(set) var failed: [String] = []
    private(set) var evidence: [String: Any] = [:]

    func pass(_ label: String) {
        passed.append(label)
        mxLog("PASS: \(label)")
    }

    func fail(_ group: String, _ detail: String) {
        failed.append("\(group): \(detail)")
        mxLog("FAIL: \(group): \(detail)")
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
        MatrixStage.mark(name)
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
        mxLog("All-page matrix: \(passed.count) passed, \(failed.count) failed")
        for failure in failed { mxLog("RED: \(failure)") }
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

// MARK: - System accessibility layer

// Self-addressed AX requests must run while the main runloop is free to answer them.
// Only Sendable value snapshots cross back; no CF/AX object leaves the detached task.
struct MatrixElement: Hashable, Sendable { let id: UInt }

struct MatrixAXNode: Sendable {
    var strings: [String: String] = [:]
    var edges: [String: [MatrixElement]] = [:]
    var enabled: Bool?
    var frame: CGRect = .zero
}

struct MatrixAXSnapshot: Sendable {
    var app = MatrixElement(id: 0)
    var focused: MatrixElement?
    var nodes: [MatrixElement: MatrixAXNode] = [:]
}

/// All native AX calls are confined to this nonisolated reader.
enum MatrixAXReader {
    static func raw(
        _ element: AXUIElement, _ attribute: String, trace: Bool = false, context: String = ""
    ) -> CFTypeRef? {
        precondition(!Thread.isMainThread, "self-addressed AX read on the main thread")
        if trace { mxLog("AX before \(context) attribute=\(attribute)") }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if trace || error != .success {
            mxLog("AX copy \(context) \(attribute) error=\(error.rawValue)")
        }
        return error == .success ? value : nil
    }

    static func elements(
        _ element: AXUIElement, _ attribute: String, trace: Bool = false, context: String = ""
    ) -> [AXUIElement] {
        (raw(element, attribute, trace: trace, context: context) as? [AXUIElement]) ?? []
    }

    static func handle(_ element: AXUIElement) -> MatrixElement { MatrixElement(id: CFHash(element)) }

    static func read(smoke: Bool = false) -> MatrixAXSnapshot {
        precondition(!Thread.isMainThread, "self-addressed AX snapshot on the main thread")
        if smoke { mxLog("ax smoke: creating the application element off-main") }
        let app = AXUIElementCreateApplication(getpid())
        var result = MatrixAXSnapshot()
        result.app = handle(app)
        if smoke { mxLog("ax smoke: reading the window list") }
        let windows = elements(app, kAXWindowsAttribute as String, trace: true, context: "node=0 role=AXApplication")
        if smoke { mxLog("ax smoke: windows \(windows.count)") }
        let focusRaw = raw(
            app, kAXFocusedUIElementAttribute as String, trace: true, context: "node=0 role=AXApplication")
        var focused: AXUIElement?
        if let focusRaw, CFGetTypeID(focusRaw) == AXUIElementGetTypeID() {
            focused = unsafeBitCast(focusRaw, to: AXUIElement.self)
            result.focused = focused.map(handle)
        }
        var root = MatrixAXNode()
        root.edges[kAXWindowsAttribute as String] = windows.map(handle)
        root.edges[kAXChildrenAttribute as String] = windows.map(handle)
        result.nodes[result.app] = root
        var stack = windows.map { ($0, 0) }
        if let focused { stack.append((focused, 0)) }
        while let (element, depth) = stack.popLast() {
            let key = handle(element)
            if result.nodes[key] != nil { continue }
            if result.nodes.count >= 3000 { break }
            let index = result.nodes.count
            let trace = smoke || index < 25
            var role = "<unread>"
            var names: CFArray?
            if trace { mxLog("AX before node=\(index) role=\(role) attribute=attributeNames") }
            let namesError = AXUIElementCopyAttributeNames(element, &names)
            if trace { mxLog("AX names node=\(index) error=\(namesError.rawValue)") }
            if namesError != .success { mxLog("AX names error=\(namesError.rawValue)") }
            let supported = Set((names as? [String]) ?? [])
            var node = MatrixAXNode()
            for attribute in [
                kAXRoleAttribute, kAXIdentifierAttribute, kAXDescriptionAttribute,
                kAXTitleAttribute, kAXValueAttribute, kAXHelpAttribute,
            ] {
                let name = attribute as String
                if supported.contains(name),
                    let value = raw(element, name, trace: trace, context: "node=\(index) role=\(role)") as? String,
                    !value.isEmpty
                {
                    node.strings[name] = value
                    if name == kAXRoleAttribute as String { role = value }
                }
            }
            if supported.contains(kAXEnabledAttribute as String) {
                node.enabled =
                    raw(element, kAXEnabledAttribute as String, trace: trace, context: "node=\(index) role=\(role)")
                    as? Bool
            }
            var origin = CGPoint.zero
            var size = CGSize.zero
            if supported.contains(kAXPositionAttribute as String),
                let value = raw(
                    element, kAXPositionAttribute as String, trace: trace, context: "node=\(index) role=\(role)"),
                CFGetTypeID(value) == AXValueGetTypeID()
            {
                _ = AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &origin)
            }
            if supported.contains(kAXSizeAttribute as String),
                let value = raw(
                    element, kAXSizeAttribute as String, trace: trace, context: "node=\(index) role=\(role)"),
                CFGetTypeID(value) == AXValueGetTypeID()
            {
                _ = AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size)
            }
            node.frame = CGRect(origin: origin, size: size)
            if supported.contains(kAXChildrenAttribute as String) {
                let children = elements(
                    element, kAXChildrenAttribute as String, trace: trace, context: "node=\(index) role=\(role)")
                node.edges[kAXChildrenAttribute as String] = children.map(handle)
                if depth < 40 { stack.append(contentsOf: children.reversed().map { ($0, depth + 1) }) }
            }
            result.nodes[key] = node
        }
        if smoke { mxLog("ax smoke: snapshot nodes \(result.nodes.count), done") }
        return result
    }

    // Used only by the existing Welcome CTA check, never to substitute for a key event.
    static func press(_ target: MatrixElement) -> Int32 {
        let app = AXUIElementCreateApplication(getpid())
        var stack = elements(app, kAXWindowsAttribute as String)
        var visited: Set<MatrixElement> = []
        while let element = stack.popLast() {
            let key = handle(element)
            guard visited.insert(key).inserted, visited.count <= 3000 else { continue }
            if key == target { return AXUIElementPerformAction(element, kAXPressAction as CFString).rawValue }
            stack.append(contentsOf: elements(element, kAXChildrenAttribute as String))
        }
        return AXError.invalidUIElement.rawValue
    }
}

@MainActor
enum MatrixAX {
    static var snapshot = MatrixAXSnapshot()
    static func refresh() async {
        MatrixMark.firstAccessibilityRead()
        mxLog("matrix snapshot: begin")
        snapshot = await Task.detached { MatrixAXReader.read() }.value
        mxLog("matrix snapshot: complete nodes=\(snapshot.nodes.count)")
    }
}

@MainActor
func mxApp() -> MatrixElement { MatrixAX.snapshot.app }

@MainActor
func mxString(_ element: MatrixElement, _ attribute: String) -> String? {
    MatrixAX.snapshot.nodes[element]?.strings[attribute]
}

@MainActor
func mxElements(_ element: MatrixElement, _ attribute: String) -> [MatrixElement] {
    MatrixAX.snapshot.nodes[element]?.edges[attribute] ?? []
}

@MainActor
func mxEnabled(_ element: MatrixElement) -> Bool? { MatrixAX.snapshot.nodes[element]?.enabled }

@MainActor
func mxChildren(_ element: MatrixElement) -> [MatrixElement] { mxElements(element, kAXChildrenAttribute as String) }

@MainActor
func mxTree(_ root: MatrixElement, limit: Int = 3000) -> [MatrixElement] {
    var found: [MatrixElement] = []
    var stack: [(MatrixElement, Int)] = [(root, 0)]
    while let (element, depth) = stack.popLast() {
        found.append(element)
        if found.count >= limit { break }
        if found.count % 100 == 0 { MatrixStage.mark("accessibility walk, \(found.count) elements") }
        guard depth < 40 else { continue }
        for child in mxChildren(element).reversed() { stack.append((child, depth + 1)) }
    }
    return found
}

@MainActor
func mxRole(_ element: MatrixElement) -> String? { mxString(element, kAXRoleAttribute as String) }

@MainActor
func mxIdentifier(_ element: MatrixElement) -> String? { mxString(element, kAXIdentifierAttribute as String) }

/// Every name a control is known by. Static text carries its string in the value attribute,
/// buttons in the title, and SwiftUI labels in the description.
@MainActor
func mxNames(_ element: MatrixElement) -> [String] {
    [
        kAXDescriptionAttribute as String, kAXTitleAttribute as String,
        kAXValueAttribute as String, kAXHelpAttribute as String,
    ].compactMap { mxString(element, $0) }
}

@MainActor
func mxName(_ element: MatrixElement) -> String? { mxNames(element).first }

@MainActor
func mxFrame(_ element: MatrixElement) -> NSRect { MatrixAX.snapshot.nodes[element]?.frame ?? .zero }

@MainActor
func mxRoot(_ title: String) throws -> MatrixElement {
    let windows = mxElements(mxApp(), kAXWindowsAttribute as String)
    for window in windows where mxString(window, kAXTitleAttribute as String) == title { return window }
    throw MatrixFailure(label: "no accessibility window titled \(title) (\(windows.count) windows)")
}

@MainActor
func mxFocusedElement() -> MatrixElement? { MatrixAX.snapshot.focused }

@MainActor
func mxFocusIdentity() -> String? {
    guard let element = mxFocusedElement() else { return nil }
    return mxIdentifier(element) ?? mxName(element) ?? mxRole(element)
}

@MainActor
func mxFocusedRole() -> String? {
    guard let element = mxFocusedElement() else { return nil }
    return mxRole(element)
}

@MainActor
func mxPress(_ element: MatrixElement) async throws {
    MatrixStage.mark("AX press \(mxIdentifier(element) ?? mxRole(element) ?? "control")")
    let error = await Task.detached { MatrixAXReader.press(element) }.value
    guard error == AXError.success.rawValue else { throw MatrixFailure(label: "AX press refused (\(error))") }
}

@MainActor
func mxText(_ root: MatrixElement) -> [String] { mxTree(root).flatMap { mxNames($0) } }

@MainActor
func mxHas(_ root: MatrixElement, _ text: String) -> Bool { mxText(root).contains(text) }

@MainActor
func mxHasContaining(_ root: MatrixElement, _ fragment: String) -> Bool {
    mxText(root).contains { $0.contains(fragment) }
}

@MainActor
func mxStaticText(_ root: MatrixElement) -> [String] {
    mxTree(root).filter { mxRole($0) == "AXStaticText" }.compactMap { mxName($0) }
}

@MainActor
func mxFind(_ root: MatrixElement, name: String) -> MatrixElement? {
    mxTree(root).first { mxNames($0).contains(name) }
}

@MainActor
func mxIdentified(_ root: MatrixElement, _ identifier: String) throws -> MatrixElement {
    let matches = mxTree(root).filter { mxIdentifier($0) == identifier }
    guard matches.count == 1, let element = matches.first else {
        throw MatrixFailure(label: "expected one \(identifier), saw \(matches.count)")
    }
    return element
}

/// Sheet content is either a child of its parent window or its own window entry; both live in
/// the application tree, and these strings exist nowhere else.
@MainActor
func mxHasInApp(_ root: MatrixElement, _ text: String) -> Bool {
    mxHas(root, text) || mxHas(mxApp(), text)
}

@MainActor
func mxIdentifiedInApp(_ root: MatrixElement, _ identifier: String) -> MatrixElement? {
    mxTree(root).first { mxIdentifier($0) == identifier }
        ?? mxTree(mxApp()).first { mxIdentifier($0) == identifier }
}

@MainActor
func mxAssertFocused(_ identity: String, _ label: String, report: MatrixReport) throws {
    let observed = mxFocusIdentity()
    try report.require(observed == identity, label, "observed \(observed ?? "none")")
}

@MainActor
func mxDumpAX(_ root: MatrixElement, _ tag: String) {
    let lines: [String] = mxTree(root).compactMap { element in
        guard let role = mxRole(element) else { return nil }
        let identifier = mxIdentifier(element) ?? ""
        let name = mxName(element) ?? ""
        guard !identifier.isEmpty || !name.isEmpty || role != "AXGroup" else { return nil }
        return "\(role)|\(identifier)|\(name)"
    }
    mxLog("AXDUMP \(tag) count=\(lines.count)")
    for line in lines.prefix(160) { mxLog("AXDUMP \(tag) \(line)") }
}

// MARK: - Key, pixel and window helpers

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
    MatrixStage.mark("key \(code) modifiers \(modifiers.rawValue)")
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        let event = try mxKeyEvent(
            code, characters, type: type, modifiers: modifiers, windowNumber: window.windowNumber)
        NSApp.sendEvent(event)
    }
    MatrixStage.mark("settle after key \(code)")
    await mxSettle()
}

@MainActor
func mxSettle(_ seconds: Double = 0.2) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    NSApp.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
    await MatrixAX.refresh()
}

/// Settle, then read the application tree once so AppKit materialises the accessibility tree.
@MainActor
func mxReady(_ seconds: Double = 1.0) async {
    await mxSettle(seconds)
    _ = mxElements(mxApp(), kAXWindowsAttribute as String)
    await mxSettle(0.2)
}

@MainActor
func mxClick(host: NSView, window: NSWindow, screenRect: NSRect) throws {
    let inWindow = window.convertFromScreen(screenRect)
    let local = host.convert(inWindow, from: nil)
    let point = CGPoint(x: local.midX, y: host.isFlipped ? local.midY : host.bounds.height - local.midY)
    // A click outside the content view can start a window drag loop, which no synthetic mouse-up
    // can end. Refuse it instead of hanging.
    guard host.bounds.contains(point) else {
        throw MatrixFailure(label: "click outside the hosted view: \(point) in \(host.bounds)")
    }
    MatrixStage.mark(
        "click \(Int(screenRect.midX)),\(Int(screenRect.midY)) size \(Int(screenRect.width))x\(Int(screenRect.height))")
    let location = host.convert(point, to: nil)
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

/// FNV-1a over the rendered PNG: a pane that never changed cannot produce a new signature.
@MainActor
func mxSignature(_ host: NSView) throws -> String {
    let bitmap = try mxBitmap(host)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw MatrixFailure(label: "no signature for host")
    }
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in data { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
    return String(hash, radix: 16)
}

/// Host-space rectangle for a screen-space accessibility frame.
@MainActor
func mxHostRect(_ screenRect: NSRect, window: NSWindow, host: NSView) -> NSRect {
    guard screenRect != .zero else { return .zero }
    return host.convert(window.convertFromScreen(screenRect), from: nil)
}

@MainActor
func mxScale(_ host: NSView, _ bitmap: NSBitmapImageRep) -> CGFloat {
    CGFloat(bitmap.pixelsWide) / max(1, host.bounds.width)
}

/// Top-down bitmap row for a host-space y coordinate.
@MainActor
func mxRow(_ y: CGFloat, host: NSView, bitmap: NSBitmapImageRep) -> Int {
    let flipped = host.isFlipped ? y : host.bounds.height - y
    return min(bitmap.pixelsHigh - 1, max(0, Int(flipped * mxScale(host, bitmap))))
}

/// Opaque sRGB colour for a shared palette token. The probe looks for the pixel a known ink
/// paints, so the reference must not be resolved through the current app appearance.
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
        MatrixStage.mark("waiting for the native menu to begin tracking")
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

    /// Deliberately authored fixture setup, not a production mutation entry point. A closed day
    /// can never be seeded through the command layer, so history is written directly, exactly as
    /// the integration probe authors its fixtures.
    func write(_ body: (inout Planner) -> Void) throws {
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

    @discardableResult
    func history(_ titles: [String], daysAgo: Int) throws -> [PlanTask] {
        let day = store.today.adding(days: -daysAgo)
        try write { planner in
            for title in titles {
                planner.tasks.append(PlanTask(title: title, day: day, done: false))
            }
        }
        let seeded = store.planner.tasks.filter { $0.day == day && titles.contains($0.title) }
        guard seeded.count == titles.count else { throw MatrixFailure(label: "could not author history \(titles)") }
        return seeded
    }
}

@MainActor
func matrixWindow<V: View>(_ title: String, _ view: V, size: NSSize, appearance: NSAppearance? = nil) throws -> (
    NSWindow, NSHostingView<V>
) {
    let host = NSHostingView(rootView: view)
    host.safeAreaRegions = []
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = title
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
        await report.group("probe preconditions") { [self] in
            // The runner passes -AppleKeyboardUIMode 3 in the argument domain; without it macOS
            // only tabs between text fields and every traversal below would be meaningless.
            try report.require(
                UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") == 3,
                "probe process runs with full keyboard access enabled")
        }
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

    func writeAX(_ root: MatrixElement, _ url: URL) throws {
        let rows: [[String: Any]] = mxTree(root).compactMap { element in
            guard let role = mxRole(element) else { return nil }
            return [
                "role": role, "id": mxIdentifier(element) ?? "", "name": mxName(element) ?? "",
                "frame": NSStringFromRect(mxFrame(element)), "enabled": mxEnabled(element) ?? false,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    /// Tab until the focused element matches, reporting the whole traversal either way.
    func tabUntil(
        _ window: NSWindow, limit: Int, tag: String, _ match: @MainActor (String, String?) -> Bool
    ) async throws -> String {
        var traversal: [String] = []
        for _ in 0..<limit {
            try await mxKey(window, 48, "\t")
            let identity = mxFocusIdentity() ?? "none"
            traversal.append("\(identity)|\(mxFocusedRole() ?? "?")")
            if match(identity, mxFocusedRole()) {
                report.record(tag, traversal)
                return identity
            }
        }
        report.record(tag, traversal)
        throw MatrixFailure(label: "traversal never reached the target: \(traversal)")
    }

    // MARK: Settings: five panes

    func settingsPanes() async throws {
        let fixture = try MatrixFixture()
        defer { fixture.close() }
        let view = SettingsView().environmentObject(fixture.store).environmentObject(fixture.services)
            .environment(\.colorScheme, .dark)
        let (window, host) = try matrixWindow("Matrix Settings", view, size: NSSize(width: 760, height: 640))
        defer { window.close() }
        await mxReady(1.4)
        let root = try mxRoot("Matrix Settings")

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
        var signatures: [String: String] = [:]
        for (pane, marker, second) in markers {
            try selectPane(pane, window: window, host: host, root: root)
            await mxReady(0.9)
            let texts = mxText(root)
            observed[pane.rawValue] = texts.count
            signatures[pane.rawValue] = try mxSignature(host)
            try report.require(
                texts.count >= 5, "settings \(pane.rawValue) detail exposes its text to accessibility",
                "labels \(texts.prefix(12))")
            try report.require(
                texts.contains(AppL10n.text(marker)), "settings \(pane.rawValue) pane shows \(marker)",
                "present \(texts.prefix(14))")
            try report.require(
                texts.contains(AppL10n.text(second)), "settings \(pane.rawValue) pane shows \(second)",
                "present \(texts.prefix(14))")
            try mxSave(host, output.appendingPathComponent("settings-\(pane.rawValue.lowercased()).png"))
            try writeAX(root, output.appendingPathComponent("settings-\(pane.rawValue.lowercased()).ax.json"))
        }
        // Selecting System must retire the General detail: the sidebar really drives the pane.
        try report.require(
            !mxHas(root, AppL10n.text("Apple Intelligence")),
            "settings detail is replaced when the pane changes")
        // A pane that never changed cannot render different pixels: all five must differ.
        try report.require(
            Set(signatures.values).count == markers.count, "each settings pane renders its own detail",
            "signatures \(signatures)")
        report.record("settingsPaneNodeCounts", observed)
        report.record("settingsPaneSignatures", signatures)
    }

    func selectPane(_ pane: SettingsView.Pane, window: NSWindow, host: NSView, root: MatrixElement) throws {
        let title = pane.title
        let nodes = mxTree(root)
        let rows = nodes.filter { (mxRole($0) ?? "").contains("Row") }
        for row in rows
        where mxNames(row).contains(title) || mxTree(row).contains(where: { mxNames($0).contains(title) }) {
            try mxClick(host: host, window: window, screenRect: mxFrame(row))
            return
        }
        // A sidebar row may expose its label only on a child static text: click that frame.
        for label in nodes where mxRole(label) == "AXStaticText" && mxNames(label).contains(title) {
            try mxClick(host: host, window: window, screenRect: mxFrame(label))
            return
        }
        mxDumpAX(root, "settings-\(pane.rawValue)")
        throw MatrixFailure(label: "no settings sidebar control for \(title) (\(nodes.count) nodes)")
    }

    // MARK: Settings: a synthetic failure path per pane

    func settingsFailurePaths() async throws {
        let fixture = try MatrixFixture()
        defer { fixture.close() }
        let view = SettingsView().environmentObject(fixture.store).environmentObject(fixture.services)
            .environment(\.colorScheme, .dark)
        let (window, host) = try matrixWindow(
            "Matrix Settings Failure", view, size: NSSize(width: 760, height: 640))
        defer { window.close() }
        await mxReady(1.4)
        let root = try mxRoot("Matrix Settings Failure")

        // General: the Apple Intelligence control must present the real availability reason and
        // follow the real availability; nothing may touch the login item.
        try selectPane(.general, window: window, host: host, root: root)
        await mxReady(0.8)
        let loginStatus = SMAppService.mainApp.status
        let expectedExplanation = SettingsView.appleIntelligenceExplanation(
            isSupported: AISorter.isSupported, unavailableReason: AISorter.unavailableReason)
        try report.require(
            mxHas(root, AppL10n.text("Auto-sort new tasks")), "general pane exposes the auto-sort control",
            "texts \(mxText(root).prefix(16))")
        try report.require(
            mxHas(root, expectedExplanation), "general pane explains the AI failure state",
            "isSupported=\(AISorter.isSupported)")
        if let checkbox = mxFind(root, name: AppL10n.text("Auto-sort new tasks")) {
            let enabled = mxEnabled(checkbox) ?? false
            try report.require(
                enabled == AISorter.isSupported, "auto-sort enablement follows real AI availability",
                "enabled=\(enabled) supported=\(AISorter.isSupported)")
        } else {
            try report.require(false, "general pane exposes the auto-sort checkbox")
        }
        try report.require(SMAppService.mainApp.status == loginStatus, "general pane never mutates the login item")

        // Workspace: the calendar row must report the state the system actually holds, and
        // reading it must not request access.
        let calendarBefore = EKEventStore.authorizationStatus(for: .event)
        let calendarState = SettingsPermissionAccess.eventState(calendarBefore).state
        try selectPane(.workspace, window: window, host: host, root: root)
        await mxReady(1.0)
        try report.require(
            mxHas(root, calendarState.title), "workspace pane reports the real calendar permission state",
            "expected \(calendarState.title)")
        try report.require(
            EKEventStore.authorizationStatus(for: .event) == calendarBefore,
            "workspace pane never requests calendar access")
        try report.require(
            calendarState == .allowed || !fixture.services.calendar.hasAccess,
            "workspace pane calendar access matches the reported state")

        // Focus: a corrupted persisted length must be surfaced, not silently rewritten.
        try fixture.write { $0.preferences.defaultFocusMinutes = 0 }
        try selectPane(.focus, window: window, host: host, root: root)
        await mxReady(0.8)
        try report.require(
            mxHas(root, AppL10n.format("%lld min", 0)), "focus pane surfaces the out-of-range length",
            "texts \(mxText(root).prefix(18))")
        try report.require(
            (try fixture.file.load()).preferences.defaultFocusMinutes == 0,
            "focus pane does not silently repair the persisted length")

        // Agents: an unbundled probe cannot install agents, so the warning must be shown and no
        // connector may change state.
        let agentStatuses = AgentConnector.App.allCases.map { AgentConnector.status($0) }
        try selectPane(.agents, window: window, host: host, root: root)
        await mxReady(0.8)
        try report.require(!AppInfo.isInApplications, "matrix probe is not installed in Applications")
        try report.require(
            mxHas(root, AppL10n.text("Agent setup requires Perch to be installed in Applications.")),
            "agents pane shows the not-installed failure path", "texts \(mxText(root).prefix(18))")
        try report.require(
            AgentConnector.App.allCases.map { AgentConnector.status($0) } == agentStatuses,
            "agents pane never mutates a connector")

        // System: the reminders row must report the real state, the dependent phone alert must be
        // disabled while mirroring is off, and no sync may run.
        let reminderBefore = EKEventStore.authorizationStatus(for: .reminder)
        let reminderState = SettingsPermissionAccess.eventState(reminderBefore).state
        let tasksBefore = fixture.store.planner.tasks.count
        try selectPane(.system, window: window, host: host, root: root)
        await mxReady(1.0)
        try report.require(
            mxHas(root, reminderState.title), "system pane reports the real reminders permission state",
            "expected \(reminderState.title)")
        if let phoneToggle = mxFind(root, name: AppL10n.text("Alert on iPhone and Apple Watch too")) {
            try report.require(
                (mxEnabled(phoneToggle) ?? true) == fixture.store.prefs.remindersSync,
                "phone alert stays disabled while mirroring is off")
        } else {
            try report.require(false, "system pane exposes the phone alert control")
        }
        try report.require(
            EKEventStore.authorizationStatus(for: .reminder) == reminderBefore,
            "system pane never requests reminders access")
        try report.require(fixture.store.planner.tasks.count == tasksBefore, "system pane never mutates the planner")
        try mxSave(host, output.appendingPathComponent("settings-system.png"))
    }

    // MARK: Dashboard: four tabs

    func dashboardTabs() async throws {
        let fixture = try MatrixFixture()
        defer { fixture.close() }
        try fixture.seed(["Matrix upcoming task"], day: .day(fixture.store.today.adding(days: 1)))
        try fixture.history(["Matrix history task"], daysAgo: 1)
        try fixture.seed(["Matrix today task"], day: .day(fixture.store.today))

        let destinations = MatrixFocusDestinations()
        let view = MatrixHarness(destinations: destinations) {
            DashboardView(tab: .upcoming)
                .environmentObject(fixture.store)
                .environment(\.accessibilityEnabled, true)
                .frame(width: 880, height: 560)
        }
        let (window, host) = try matrixWindow("Matrix Dashboard", view, size: NSSize(width: 900, height: 620))
        defer { window.close() }
        await mxReady(1.4)
        let root = try mxRoot("Matrix Dashboard")
        try report.require(window.makeFirstResponder(destinations.before), "dashboard fixture starts from a field")

        // One keyboard-reachability assertion for the tab group itself.
        _ = try await tabUntil(window, limit: 16, tag: "dashboardTabTraversal") { _, role in role == "AXRadioButton" }
        try report.require(true, "Tab reaches the dashboard tab controls")

        // Every tab is exercised through the real segmented control.
        let markers: [(DashboardView.Tab, String, String)] = [
            (.upcoming, "Matrix upcoming task", "Matrix history task"),
            (.history, "Matrix history task", "Matrix upcoming task"),
            (.insights, AppL10n.text("Streak"), "Matrix history task"),
            (.projects, AppL10n.text("No projects yet. Add #project to a new task."), "Matrix history task"),
        ]
        for (tab, marker, foreign) in markers {
            let wanted = AppL10n.text(tab.rawValue)
            let nodes = mxTree(root)
            let segment =
                nodes.first { mxRole($0) == "AXRadioButton" && mxNames($0).contains(wanted) }
                ?? nodes.first { mxRole($0) == "AXStaticText" && mxNames($0).contains(wanted) }
            guard let segment else {
                mxDumpAX(root, "dashboard-\(tab.rawValue)")
                throw MatrixFailure(label: "no dashboard segment for \(tab.rawValue)")
            }
            try mxClick(host: host, window: window, screenRect: mxFrame(segment))
            await mxReady(0.8)
            let texts = mxText(root)
            try report.require(
                texts.contains(marker) || mxHasContaining(root, marker),
                "dashboard \(tab.rawValue) tab renders its own content", "present \(texts.prefix(12))")
            try report.require(
                !texts.contains(foreign), "dashboard \(tab.rawValue) tab retires the other panes",
                "leaked \(foreign)")
        }
        try mxSave(host, output.appendingPathComponent("dashboard-tabs.png"))
    }

    // MARK: Dashboard: task-line and project actions from real key events

    func dashboardActions() async throws {
        let fixture = try MatrixFixture()
        defer { fixture.close() }
        guard fixture.store.addTasks(["Matrix project task #Matrix"], on: .day(fixture.store.today)) != nil,
            let project = fixture.store.planner.projects.first
        else { throw MatrixFailure(label: "could not seed a project through the parser") }
        try fixture.history(["Matrix history alpha", "Matrix history beta"], daysAgo: 1)

        let destinations = MatrixFocusDestinations()
        let projectView = MatrixHarness(destinations: destinations) {
            DashboardView(tab: .projects)
                .environmentObject(fixture.store)
                .environment(\.accessibilityEnabled, true)
                .frame(width: 880, height: 560)
        }
        let (window, _) = try matrixWindow(
            "Matrix Dashboard Project", projectView, size: NSSize(width: 900, height: 620))
        defer { window.close() }
        await mxReady(1.4)
        try report.require(window.makeFirstResponder(destinations.before), "project fixture starts from a field")

        let deleteLabel = AppL10n.text("Delete project")
        _ = try await tabUntil(window, limit: 24, tag: "projectActionTraversal") { identity, _ in
            identity == deleteLabel
        }
        try report.require(true, "Tab reaches the delete-project action")
        let taskCount = fixture.store.planner.tasks.count
        try await mxKey(window, 49, " ")
        await mxReady(0.7)
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
        let (historyWindow, historyHost) = try matrixWindow(
            "Matrix Dashboard History", historyView, size: NSSize(width: 900, height: 620))
        defer { historyWindow.close() }
        await mxReady(1.4)
        let historyRoot = try mxRoot("Matrix Dashboard History")
        try report.require(
            historyWindow.makeFirstResponder(destinations.before), "history fixture starts from a field")
        _ = try await tabUntil(historyWindow, limit: 16, tag: "historySearchTraversal") { _, role in
            role == "AXTextField"
        }
        try report.require(true, "Tab reaches the history search field")
        let before = mxStaticText(historyRoot).filter { $0.contains("Matrix history") }.count
        try report.require(before == 2, "history lists both seeded task lines", "count \(before)")
        for character in "Matrix history alpha".map(String.init) {
            let scalar = character.unicodeScalars.first?.value ?? 0
            try await mxKey(historyWindow, 0, character, modifiers: scalar >= 65 && scalar <= 90 ? .shift : [])
        }
        await mxReady(0.9)
        let typed = mxFocusedElement().flatMap { mxString($0, kAXValueAttribute as String) }
        try report.require(
            typed == "Matrix history alpha", "typed keys land in the history search field",
            "value \(typed ?? "none")")
        let after = mxStaticText(historyRoot).filter { $0.contains("Matrix history") }.count
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
        let (window, host) = try matrixWindow("Matrix Welcome", view, size: NSSize(width: 560, height: 900))
        defer { window.close() }
        await mxReady(1.6)
        let root = try mxRoot("Matrix Welcome")

        try report.require(
            mxHas(root, AppL10n.text("Your plan, close at hand.")), "welcome renders its heading",
            "texts \(mxText(root).prefix(16))")
        // Every permission row must show the state the system actually holds: with no grant, the
        // failure state is what the user sees, and the CTA must still work.
        var states: [String: String] = [:]
        let access = SettingsPermissionAccess(services: fixture.services)
        for feature in PermissionFeature.allCases {
            let reading = await access.read(feature)
            states[feature.rawValue] = reading.state.rawValue
            try report.require(
                mxHas(root, reading.state.title), "welcome shows \(feature.rawValue) as \(reading.state.title)",
                "texts \(mxText(root).prefix(24))")
        }
        report.record("welcomePermissionStates", states)
        let allowedRows = mxText(root).filter { $0 == PermissionState.allowed.title }.count
        let allowedStates = states.values.filter { $0 == PermissionState.allowed.rawValue }.count
        try report.require(
            allowedRows == allowedStates, "welcome never claims access the system did not grant",
            "rows \(allowedRows) states \(allowedStates)")

        // A keybinding registration failure is a real error surface: the view must re-read and
        // keep rendering instead of dropping the shortcut line.
        NotificationCenter.default.post(name: ShortcutStore.didFail, object: nil)
        await mxReady(0.6)
        let display = ShortcutStore.load().display
        try report.require(
            mxHasContaining(root, display), "welcome keeps the shortcut line after a registration failure",
            "display \(display)")
        try report.require(
            mxHas(root, AppL10n.text("Skip any permission. You can review it later in Settings.")),
            "welcome keeps the skip promise in the failure state")

        guard let cta = mxFind(root, name: AppL10n.text("Open workspace")) else {
            mxDumpAX(root, "welcome")
            throw MatrixFailure(label: "welcome has no Open workspace action")
        }
        try await mxPress(cta)
        await mxReady(0.5)
        try report.require(opened == 1, "welcome opens the workspace without any permission")
        try mxSave(host, output.appendingPathComponent("welcome-failure-state.png"))
    }

    // MARK: Details: historical and error states

    func detailsStates() async throws {
        let fixture = try MatrixFixture()
        defer { fixture.close() }
        guard let past = try fixture.history(["Matrix past task"], daysAgo: 1).first else {
            throw MatrixFailure(label: "could not author the historical task")
        }
        try fixture.seed(["Matrix today task"], day: .day(fixture.store.today))
        let (window, host) = try matrixWindow(
            "Matrix Details", workspaceFixture(fixture), size: NSSize(width: 880, height: 520))
        defer { window.close() }
        await mxReady(1.4)
        let root = try mxRoot("Matrix Details")

        // Historical task: a read-only sheet, never an editable one.
        fixture.model.detailsTaskID = past.id
        await mxReady(1.4)
        guard let sheet = window.attachedSheet else {
            throw MatrixFailure(label: "details sheet did not attach for a past task")
        }
        try report.require(
            mxHasInApp(root, AppL10n.text("Earlier days are read-only. Your history and focus time stay unchanged.")),
            "details sheet shows the historical read-only state", "texts \(mxText(root).prefix(20))")
        try report.require(
            mxIdentifiedInApp(root, "details-title") == nil,
            "historical details expose no editable title field")
        if let save = mxIdentifiedInApp(root, "details-save") {
            try report.require(mxEnabled(save) == false, "historical details cannot save")
        } else {
            try report.require(false, "historical details expose the save control")
        }
        try await mxKey(sheet, 53, "\u{1b}")
        await mxReady(1.2)
        try report.require(window.attachedSheet == nil, "Escape dismisses the historical details sheet")
        try report.require(
            fixture.store.planner.tasks.contains { $0.id == past.id && $0.title == "Matrix past task" },
            "dismissing historical details leaves the task unchanged")
        try report.require(window.isKeyWindow, "workspace keeps the key window after dismiss")
        // Keyboard focus must be usable in the workspace again, not stranded on a dead sheet.
        try await mxKey(window, 48, "\t")
        await mxSettle(0.3)
        if let focused = mxFocusedElement() {
            let inWorkspace = mxTree(root).contains { $0 == focused }
            try report.require(
                inWorkspace, "focus returns into the workspace after dismiss",
                "focused \(mxName(focused) ?? mxRole(focused) ?? "unknown")")
        } else {
            try report.require(false, "focus returns into the workspace after dismiss")
        }

        // Removed task: the error state, not a blank sheet.
        fixture.model.detailsTaskID = UUID()
        await mxReady(1.4)
        guard let errorSheet = window.attachedSheet else {
            throw MatrixFailure(label: "details sheet did not attach for a removed task")
        }
        try report.require(
            mxHasInApp(root, AppL10n.text("Task unavailable")), "removed task shows the unavailable state",
            "texts \(mxText(root).prefix(18))")
        try report.require(
            mxHasInApp(root, AppL10n.text("This task was removed.")), "removed task explains what happened")
        try report.require(
            mxIdentifiedInApp(root, "details-close") != nil,
            "removed task offers an explicit close control")
        try mxSave(host, output.appendingPathComponent("details-error-state.png"))
        try await mxKey(errorSheet, 53, "\u{1b}")
        await mxReady(1.2)
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
        let (window, host) = try matrixWindow("Matrix Week", view, size: NSSize(width: 880, height: 520))
        defer { window.close() }
        await mxReady(1.4)
        let root = try mxRoot("Matrix Week")
        try report.require(window.makeFirstResponder(destinations.before), "week fixture starts from a field")

        // The Inbox toggle is a real keyboard action with a visible consequence.
        let inboxTitle = AppL10n.format("Inbox (%lld)", fixture.store.engine.tasks(on: .inbox).count)
        _ = try await tabUntil(window, limit: 28, tag: "weekKeyboardTraversal") { identity, _ in
            identity == "week-inbox"
        }
        try report.require(true, "Tab reaches the Inbox toggle")
        try report.require(mxHas(root, inboxTitle), "week header shows the Inbox count", "expected \(inboxTitle)")
        try await mxKey(window, 49, " ")
        await mxReady(0.8)
        try report.require(
            mxHas(root, AppL10n.text("Back to week")), "Space on the Inbox toggle swaps the week for the Inbox",
            "texts \(mxText(root).prefix(18))")
        try await mxKey(window, 49, " ")
        await mxReady(0.8)
        try report.require(mxHas(root, inboxTitle), "Space returns to the week view")

        // The task-line menu: a real key press opens a real native menu, Escape closes it, and
        // focus returns to the control that opened it.
        let menuID = "week-menu-\(task.id)"
        _ = try await tabUntil(window, limit: 40, tag: "weekMenuTraversal") { identity, _ in
            identity == menuID
        }
        try report.require(true, "Tab reaches the task-line actions menu")
        let tasksBefore = fixture.store.planner.tasks.map { "\($0.id)-\($0.title)-\($0.done)" }

        let observation = MatrixMenuObservation()
        observation.start()
        defer { observation.stop() }
        try await mxKey(window, 49, " ")
        guard let menu = await observation.waitForMenu() else {
            mxDumpAX(root, "week-menu")
            throw MatrixFailure(label: "Space did not open the task-line menu")
        }
        let titles = menu.items.map { $0.title }
        try report.require(
            titles.contains(AppL10n.text("Details…")), "task-line menu opens with Details", "items \(titles)")
        try report.require(titles.contains(AppL10n.text("Move to day")), "task-line menu opens with Move to day")
        try report.require(
            menu.items.contains { $0.title == AppL10n.text("Delete") && $0.isEnabled },
            "task-line menu opens with an enabled Delete")
        try await mxKey(window, 53, "\u{1b}")
        observation.cancel()
        await mxReady(0.7)
        try mxAssertFocused(menuID, "Escape returns focus to the task-line menu control", report: report)
        try report.require(
            fixture.store.planner.tasks.map { "\($0.id)-\($0.title)-\($0.done)" } == tasksBefore,
            "opening and cancelling the menu never mutates the task")

        // Nested Escape: the task line opens a sheet over the page; Escape dismisses it and the
        // task line stays intact with keyboard focus usable again.
        fixture.model.detailsTaskID = task.id
        await mxReady(1.4)
        guard let sheet = window.attachedSheet else {
            throw MatrixFailure(label: "week details sheet did not attach")
        }
        try report.require(
            mxHasInApp(root, AppL10n.text("Task details")), "week details sheet shows the editable state",
            "texts \(mxText(root).prefix(18))")
        try await mxKey(sheet, 53, "\u{1b}")
        await mxReady(1.2)
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
        let (window, host) = try matrixWindow("Matrix Clips", view, size: NSSize(width: 880, height: 440))
        defer { window.close() }
        await mxReady(1.4)
        let root = try mxRoot("Matrix Clips")
        try report.require(window.makeFirstResponder(destinations.before), "clips fixture starts from a field")

        // Keyboard copy: Space on the focused copy control, into the recording pasteboard.
        let copyLabel = AppL10n.format("Copy %@", first.title)
        _ = try await tabUntil(window, limit: 28, tag: "clipsCopyTraversal") { identity, _ in
            identity == copyLabel
        }
        try report.require(true, "Tab reaches the clip copy control")
        try await mxKey(window, 49, " ")
        await mxReady(0.6)
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
        _ = try await tabUntil(window, limit: 28, tag: "clipsMenuTraversal") { identity, _ in
            identity == actionsID
        }
        try report.require(true, "Tab reaches the clip actions menu")
        let pinnedBefore = clips.clips.map { $0.pinned }
        let observation = MatrixMenuObservation()
        observation.start()
        defer { observation.stop() }
        try await mxKey(window, 49, " ")
        guard let menu = await observation.waitForMenu() else {
            mxDumpAX(root, "clips-menu")
            throw MatrixFailure(label: "Space did not open the clip actions menu")
        }
        let titles = menu.items.map { $0.title }
        try report.require(titles.contains(AppL10n.text("Pin")), "clip actions menu opens with Pin", "items \(titles)")
        try report.require(titles.contains(AppL10n.text("Remove")), "clip actions menu opens with Remove")
        try await mxKey(window, 53, "\u{1b}")
        observation.cancel()
        await mxReady(0.7)
        try mxAssertFocused(actionsID, "Escape returns focus to the clip actions menu", report: report)
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
            let (window, host) = try matrixWindow(
                "Matrix Enlarged \(name)", view, size: NSSize(width: 440, height: 230))
            await mxReady(1.4)
            let root = try mxRoot("Matrix Enlarged \(name)")
            let statusTitle = PermissionState.unavailable.title
            guard let status = mxFind(root, name: statusTitle) else {
                mxDumpAX(root, "enlarged-\(name)")
                window.close()
                throw MatrixFailure(label: "no \(statusTitle) status label at \(name)")
            }
            let frame = mxHostRect(mxFrame(status), window: window, host: host)
            let bitmap = try mxBitmap(host)
            let rows = mxInkRows(bitmap, host: host, band: frame, ink: warningInk)
            let fixedFrame = mxHostRect(
                mxFrame(try mxIdentified(root, "matrix-fixed-label")), window: window, host: host)
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
        let increased = UserDefaults(suiteName: "com.apple.universalaccess")?.bool(forKey: "increaseContrast") ?? false
        report.record("increaseContrastPreference", increased)
        try report.require(increased, "the runner is in the system increase-contrast state")
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
            let (window, host) = try matrixWindow(
                "Matrix Contrast \(mode)", view, size: NSSize(width: 440, height: 220), appearance: appearance)
            await mxReady(1.4)
            let root = try mxRoot("Matrix Contrast \(mode)")
            let effective = window.effectiveAppearance.name.rawValue
            try report.require(
                effective == appearanceName.rawValue, "\(mode) window runs in the increased-contrast appearance",
                "effective \(effective)")
            // The panel renders the reading's own detail when it has one (an unbundled process
            // cannot get notification access), so measure the line that is actually drawn.
            let reading = await SettingsPermissionAccess(services: fixture.services).read(.notifications)
            let detail = reading.detail ?? PermissionFeature.notifications.detail
            guard let detailNode = mxFind(root, name: detail) else {
                mxDumpAX(root, "contrast-\(mode)")
                window.close()
                throw MatrixFailure(label: "no permission detail text at \(mode)")
            }
            let bitmap = try mxBitmap(host)
            let detailRect = mxHostRect(mxFrame(detailNode), window: window, host: host)
            guard let background = mxDominant(bitmap, host: host, band: detailRect),
                let ink = mxInkSample(bitmap, host: host, band: detailRect, near: bodyInk)
            else {
                window.close()
                throw MatrixFailure(label: "could not sample rendered text at \(mode)")
            }
            let ratio = mxContrast(ink, background)
            try report.require(
                ratio >= 4.5, "\(mode) renders body text above 4.5:1", "measured \(String(format: "%.2f", ratio))")

            // Negative control: the same measurement must flag a genuinely low-contrast label.
            let lowRect = mxHostRect(
                mxFrame(try mxIdentified(root, "matrix-low-contrast")), window: window, host: host)
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
mxLog("matrix probe start (smoke=\(CommandLine.arguments.contains("--ax-smoke")))")
// Argument-domain override only: the probe never writes the user's keyboard preferences.
var matrixArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
matrixArguments["AppleKeyboardUIMode"] = 3
UserDefaults.standard.setVolatileDomain(matrixArguments, forName: UserDefaults.argumentDomain)

/// One accessibility read per API, nothing else: if the process traps here the fault is the AX
/// API itself rather than any measurement.
@MainActor
func matrixAccessibilitySmoke() async -> Never {
    // A real visible window makes an empty snapshot a failure, not a passing smoke.
    let (window, _) = try! matrixWindow(
        "Matrix AX smoke", Text("Matrix AX smoke control"), size: NSSize(width: 320, height: 160))
    await Task.yield()
    MatrixMark.firstAccessibilityRead()
    let snapshot = await Task.detached { MatrixAXReader.read(smoke: true) }.value
    let windows = snapshot.nodes[snapshot.app]?.edges[kAXWindowsAttribute as String] ?? []
    let hasWindow = windows.contains { snapshot.nodes[$0]?.strings[kAXTitleAttribute as String] == window.title }
    mxLog("ax smoke: expected window observed=\(hasWindow)")
    window.close()
    exit(hasWindow ? 0 : 1)
}

Task { @MainActor in
    if CommandLine.arguments.contains("--ax-smoke") { await matrixAccessibilitySmoke() }
    MatrixStage.startWatchdog()
    let output =
        ProcessInfo.processInfo.environment["MATRIX_OUTPUT"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("allpage-matrix")
    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    await AllPageMatrix(output: output).run()
}
matrixApplication.run()
