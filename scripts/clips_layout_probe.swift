// Temporary CI entry point only. Renders the actual ClipsPage; never touches the clipboard.
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
    let rows: [[String: Any]] = clipsNodes(host).map { node in
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
    let matches = clipsNodes(host).filter { node in
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

@MainActor
func clipsFooterFrame(in host: NSView) throws -> NSRect {
    let message = "Click to copy · Drag to share · More for clip actions"
    let matches = clipsNodes(host).filter {
        clipsAttribute($0, "accessibilityRole") as? String == "AXStaticText"
            && (clipsAttribute($0, "accessibilityValue") as? String == message
                || clipsAttribute($0, "accessibilityLabel") as? String == message)
    }
    try requireClips(matches.count == 1, "Expected the visible fixed footer")
    return try clipsFrame(matches[0], in: host)
}

@MainActor
func checkClipsScrolling(host: NSView) async throws {
    let footer = try clipsFooterFrame(in: host)
    try requireClips(host.bounds.insetBy(dx: 24, dy: 24).contains(footer), "Footer outside card")
    let scrolls = clipsNodes(host).compactMap { $0 as? NSScrollView }.filter { $0.documentView != nil }
    try requireClips(scrolls.count == 1, "Expected one real Clips scroll view")
    let scroll = scrolls[0]
    let viewport = host.convert(scroll.contentView.bounds, from: scroll.contentView)
    try requireClips(!viewport.intersects(footer), "Scroll viewport overlaps fixed footer")
    let before = scroll.contentView.bounds.origin
    let end = scroll.documentView!.bounds.width - scroll.contentView.bounds.width
    if host.bounds.width <= 640 {
        try requireClips(end > before.x + 1, "Compact populated fixture must overflow")
    }
    guard end > before.x + 1 else { return }
    scroll.contentView.scroll(to: NSPoint(x: end, y: before.y))
    scroll.reflectScrolledClipView(scroll.contentView)
    await settleClips()
    try requireClips(scroll.contentView.bounds.origin.x > before.x, "Native scroll did not move")
    let after = try clipsFooterFrame(in: host)
    try requireClips(
        abs(after.minY - footer.minY) < 0.5 && abs(after.minX - footer.minX) < 0.5,
        "Footer moved with the clips")
    scroll.contentView.scroll(to: before)
    scroll.reflectScrolledClipView(scroll.contentView)
    await settleClips()
}

@MainActor
func checkClipsToolbarFrames(_ frames: [NSRect], in bounds: NSRect) throws {
    let names = ["Add screenshots", "Add copied items", "Remove unpinned"]
    try requireClips(frames.count == names.count, "Missing toolbar control frames")
    for (name, frame) in zip(names, frames) {
        try requireClips(bounds.insetBy(dx: 24, dy: 24).contains(frame), "Control outside card: \(name)")
        try requireClips(frame.height >= 28, "Control target below 28pt: \(name), \(frame)")
    }
    for i in frames.indices {
        for j in frames.indices where j > i {
            try requireClips(!frames[i].intersects(frames[j]), "Toolbar controls overlap")
        }
    }
    if bounds.width <= 640 {
        try requireClips(
            frames[0].minY >= frames[2].maxY + Theme.gutter
                && frames[1].minY >= frames[2].maxY + Theme.gutter,
            "Compact capture controls must reflow below the heading row")
    }
}

@MainActor
func checkClipsGeometryMatching() throws {
    let bounds = NSRect(x: 0, y: 0, width: 640, height: 360)
    let valid = [
        NSRect(x: 38, y: 78, width: 160, height: 32),
        NSRect(x: 206, y: 78, width: 160, height: 32),
        NSRect(x: 484, y: 38, width: 118, height: 32),
    ]
    try checkClipsToolbarFrames(valid, in: bounds)
    var small = valid
    small[0].size.height = 20
    var overlapping = valid
    overlapping[1] = overlapping[0]
    var outside = valid
    outside[0].origin.x = 0
    let singleRow = valid.map { NSRect(x: $0.minX, y: 38, width: $0.width, height: $0.height) }
    for invalid in [small, overlapping, outside, singleRow, Array(valid.prefix(2))] {
        var rejected = false
        do { try checkClipsToolbarFrames(invalid, in: bounds) } catch { rejected = true }
        try requireClips(rejected, "Toolbar geometry accepted an invalid fixture")
    }
    try checkClipsToolbarFrames(singleRow, in: NSRect(x: 0, y: 0, width: 820, height: 360))
}

// Compare encoded RGB samples, just like measure_clips_bounds.py. Converting to
// deviceRGB changes the numeric meaning of the fixed pixel threshold.
func clipsRopeRow(firstY: Int, lastY: Int, scale: CGFloat, pixel: (Int, Int) -> [Int]) -> Int? {
    for y in firstY..<lastY {
        for x in Int(43 * scale)..<Int(50 * scale) {
            let rgb = Array(pixel(x, y).prefix(3))
            if rgb.count == 3 && rgb.min()! > 45 && rgb.max()! - rgb.min()! < 5 { return y }
        }
    }
    return nil
}

func checkClipsRopeMatching() throws {
    for scale in [1, 2] {
        let width = 100 * scale
        var pixels = Array(repeating: [29, 29, 29, 255], count: width * 180 * scale)
        let firstY = 118 * scale
        let lastY = 158 * scale
        let ropeY = 131 * scale
        for y in ropeY..<(ropeY + 2 * scale) {
            for x in (43 * scale)..<(50 * scale) { pixels[y * width + x] = [85, 85, 85, 255] }
        }
        func row() -> Int? {
            clipsRopeRow(firstY: firstY, lastY: lastY, scale: CGFloat(scale)) { pixels[$1 * width + $0] }
        }
        try requireClips(row() == ropeY, "Raw RGB detector missed the rope at \(scale)x")
        for y in (ropeY - 2 * scale)..<(ropeY + 14 * scale) {
            for x in (43 * scale)..<(50 * scale) { pixels[y * width + x] = [0, 0, 0, 255] }
        }
        try requireClips(row() == nil, "Raw RGB detector accepted erased rope at \(scale)x")
        pixels[ropeY * width + 44 * scale] = [45, 45, 45, 255]
        try requireClips(row() == nil, "Raw RGB detector weakened its brightness threshold")
        pixels[ropeY * width + 44 * scale] = [85, 90, 85, 255]
        try requireClips(row() == nil, "Raw RGB detector weakened its neutrality threshold")
    }
}

// Recognize each complete label on ONE rendered line. Joining OCR lines (or checking AX
// labels alone) would wrongly accept the old "Add / screenshot / s" narrow layout.
@MainActor
func checkClipsToolbar(_ url: URL, host: NSView) throws -> [String: Any] {
    let names = ["Add screenshots", "Add copied items", "Remove unpinned"]
    let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url))!
    let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
    // Read pixels before consulting AX. Otherwise a missing native label can
    // hide the whole-label regression behind an unrelated selector failure.
    let box = CGRect(
        x: 24 * scale, y: 24 * scale,
        width: (host.bounds.width - 48) * scale, height: (host.bounds.height - 48) * scale)
    let image = bitmap.cgImage!.cropping(to: box)!
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = false
    request.minimumTextHeight = 0.01
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    try JSONSerialization.data(withJSONObject: lines, options: [.prettyPrinted])
        .write(to: url.deletingPathExtension().appendingPathExtension("ocr.json"))
    try requireClips(
        names.allSatisfy { name in lines.contains { $0.contains(name) } },
        "Toolbar labels must be whole single lines at \(Int(host.bounds.width))pt; OCR: \(lines)")
    var frames: [NSRect] = []
    for name in names {
        frames.append(try clipsFrame(clipsControl(name, in: host), in: host))
    }
    // NSHostingView uses flipped coordinates; image coordinates are always top-down.
    let bottom = frames.map { host.isFlipped ? $0.maxY : host.bounds.height - $0.minY }.max()!
    let imageFrames = frames.map { frame in
        host.isFlipped
            ? frame
            : NSRect(
                x: frame.minX, y: host.bounds.height - frame.maxY, width: frame.width, height: frame.height)
    }
    try checkClipsToolbarFrames(imageFrames, in: host.bounds)

    // Locate the actual rope's left end in the captured pixels BELOW the measured
    // toolbar. Only translate the scanner's existing 7 x 34pt ROI; do not widen it.
    let firstY = Int(ceil((bottom + Theme.gutter) * scale))
    let lastY = min(bitmap.pixelsHigh, firstY + Int(ClipsLineLayout.bandHeight * scale))
    try requireClips(
        bitmap.bitsPerSample == 8 && !bitmap.isPlanar
            && bitmap.colorSpace.colorSpaceModel == .rgb
            && [3, 4].contains(bitmap.samplesPerPixel),
        "Rope capture must decode as packed 8-bit RGB or RGBA")
    @MainActor func rawPixel(_ image: NSBitmapImageRep, x: Int, y: Int) -> [Int] {
        var samples = [Int](repeating: 0, count: image.samplesPerPixel)
        image.getPixel(&samples, atX: x, y: y)
        return samples
    }
    @MainActor func ropeRow(in image: NSBitmapImageRep) -> Int? {
        clipsRopeRow(firstY: firstY, lastY: lastY, scale: scale) { x, y in
            rawPixel(image, x: x, y: y)
        }
    }
    let ropeY = ropeRow(in: bitmap)
    let legacyRow = (firstY..<lastY).first { y in
        (Int(43 * scale)..<Int(50 * scale)).contains { x in
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            let rgb = [color.redComponent, color.greenComponent, color.blueComponent].map { $0 * 255 }
            return rgb.min()! > 45 && rgb.max()! - rgb.min()! < 5
        }
    }
    let diagnosticURL = url.deletingPathExtension().appendingPathExtension("rope.json")
    var diagnostics: [String: Any] = [
        "firstY": firstY, "lastY": lastY, "ropeY": ropeY ?? -1,
        "legacyDeviceRGBFirstRow": legacyRow ?? -1,
        "backgroundRGB": rawPixel(bitmap, x: Int(44 * scale), y: firstY),
    ]
    try JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys])
        .write(to: diagnosticURL)
    try requireClips(ropeY != nil, "No rope below toolbar in actual capture")
    // Negative control for anchor discovery itself: erase only the rope strip
    // in an in-memory copy, leaving other header/content pixels untouched.
    let noRope = NSBitmapImageRep(data: try Data(contentsOf: url))!
    var black = [0, 0, 0, 255]
    for y in max(firstY, ropeY! - Int(2 * scale))..<min(lastY, ropeY! + Int(14 * scale)) {
        for x in Int(43 * scale)..<Int(50 * scale) { noRope.setPixel(&black, atX: x, y: y) }
    }
    let erasedRow = ropeRow(in: noRope)
    diagnostics["erasedFirstRow"] = erasedRow ?? -1
    diagnostics["ropeRGB"] = rawPixel(bitmap, x: Int(44 * scale), y: ropeY!)
    diagnostics["erasedRGB"] = rawPixel(noRope, x: Int(44 * scale), y: ropeY!)
    try JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys])
        .write(to: diagnosticURL)
    try noRope.representation(using: .png, properties: [:])!
        .write(to: url.deletingPathExtension().appendingPathExtension("rope-removed.png"))
    try requireClips(erasedRow == nil, "Rope anchor detector accepted a rope-less capture")
    return ["toolbarBottom": bottom, "toolbarLines": lines, "ropeY": CGFloat(ropeY!) / scale]
}

#if CLIPS_PREVIEW_REGRESSION
    @MainActor
    private struct ClipsProbePasteboard: PasteboardAccess {
        let changeCount = 0
        let declaredTypes: [String] = []
        let fileURLs: [URL] = []
        let imageData: Data? = nil
        let plainText: String? = nil
        func replace(with value: PasteboardValue) { fatalError("Capture controls must not write the clipboard") }
    }

    @MainActor
    func checkCaptureToggleInteractions(window: NSWindow, out: URL) async throws {
        // Use the real page body and preference bindings, but no Services aggregator:
        // enabling a control must never start a real monitor in this fixture.
        let file = PlannerFile(url: out.appendingPathComponent("capture-controls-planner.json"))
        let store = PlannerStore(file: file, watching: false)
        store.updatePrefs {
            $0.catchScreenshots = false
            $0.catchCopies = false
            $0.remindersSync = false
        }
        let clips = ClipsService(store: store, pasteboard: ClipsProbePasteboard(), monitoring: false)
        let controls: [(String, WritableKeyPath<Preferences, Bool>)] = [
            ("Add screenshots", \.catchScreenshots), ("Add copied items", \.catchCopies),
        ]
        var checks: [[String: Any]] = []
        for width in [640, 820] {
            let size = NSSize(width: width, height: 360)
            window.appearance = NSAppearance(named: .darkAqua)
            let view = installClipsFixture(
                ClipsBody(clips: clips).environmentObject(store)
                    .environment(\.accessibilityEnabled, true).environment(\.colorScheme, .dark)
                    .padding(24).background(Color.black), in: window, size: size)
            await settleClips()
            for (index, control) in controls.enumerated() {
                let (title, key) = control
                let otherKey = controls[1 - index].1
                for enabled in [true, false] {
                    let prefix = "capture-\(width)-\(index)-\(enabled)"
                    try writeClipsAccessibility(view, to: out.appendingPathComponent("\(prefix)-before.ax.json"))
                    try pressClips(title, in: view)
                    await settleClips()
                    let url = out.appendingPathComponent("\(prefix).png")
                    try capture(view, size: size, to: url)
                    try writeClipsAccessibility(view, to: url.deletingPathExtension().appendingPathExtension("ax.json"))
                    _ = try checkClipsToolbar(url, host: view)
                    let persisted = try file.load().preferences
                    try requireClips(
                        store.prefs[keyPath: key] == enabled && persisted[keyPath: key] == enabled,
                        "Native capture control did not persist its state: \(title)")
                    try requireClips(
                        !store.prefs[keyPath: otherKey] && !persisted[keyPath: otherKey],
                        "Native capture control changed the other preference")
                    let node = try clipsControl(title, in: view)
                    let state = clipsToggleState(
                        role: clipsAttribute(node, "accessibilityRole") as? String,
                        value: clipsAttribute(node, "accessibilityValue"))
                    try requireClips(state == enabled, "Capture control did not expose its state")
                    checks.append(["width": width, "control": title, "enabled": enabled, "passed": true])
                }
            }
        }
        try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("capture-control-checks.json"))
    }
#endif

// Observe the menu opened by the actual More control, not reconstructed actions.
@MainActor
final class ClipsMenuTracker: NSObject {
    var menu: NSMenu?
    private var tracking: NSMenu?
    private var timer: Timer?
    private let deadline = ProcessInfo.processInfo.systemUptime + 3
    func start() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(began(_:)),
            name: NSMenu.didBeginTrackingNotification, object: nil)
        let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .default)
    }
    func stop() {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
    @objc private func began(_ notification: Notification) { tracking = notification.object as? NSMenu }
    @objc private func tick() {
        if let tracking, tracking.items.contains(where: { $0.title == "Remove" }) {
            menu = tracking
            tracking.cancelTracking()
            timer?.invalidate()
        } else if ProcessInfo.processInfo.systemUptime >= deadline {
            tracking?.cancelTracking()
            timer?.invalidate()
        }
    }
}

@MainActor
func clipsMenuAction(
    _ action: String, title: String, host: NSView, expectsOpen: Bool, out: URL,
    beforeAction: @MainActor () throws -> Void = {}
) throws {
    // Retain the exact kept-row state before the first selector or press can fail.
    let diagnostic = out.appendingPathComponent("kept-file-menu-before.ax.json")
    if !FileManager.default.fileExists(atPath: diagnostic.path) {
        try capture(
            host, size: NSSize(width: 820, height: 360), to: out.appendingPathComponent("kept-file-menu-before.png"))
        try writeClipsAccessibility(host, to: diagnostic)
    }
    let control = try clipsControl("Actions for \(title)", in: host)
    let frame = try clipsFrame(control, in: host)
    try requireClips(frame.height >= 28 && frame.width >= 28, "Clip menu target below 28pt: \(frame)")
    try requireClips(host.bounds.insetBy(dx: 24, dy: 24).contains(frame), "Clip menu target outside card")
    let tracker = ClipsMenuTracker()
    tracker.start()
    defer { tracker.stop() }
    try pressClips("Actions for \(title)", in: host)
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while tracker.menu == nil && ProcessInfo.processInfo.systemUptime < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    guard let menu = tracker.menu else {
        throw NSError(domain: "ClipsLayout", code: 4, userInfo: [NSLocalizedDescriptionKey: "More did not open menu"])
    }
    let menuEvidence: [String: Any] = [
        "requestedAction": action, "controlNames": clipsNames(control),
        "controlRole": clipsAttribute(control, "accessibilityRole") as? String ?? "",
        "controlIdentifier": clipsAttribute(control, "accessibilityIdentifier") as? String ?? "",
        "frame": NSStringFromRect(frame),
        "items": menu.items.map { ["title": $0.title, "enabled": $0.isEnabled] as [String: Any] },
    ]
    try JSONSerialization.data(withJSONObject: menuEvidence, options: [.prettyPrinted, .sortedKeys])
        .write(to: out.appendingPathComponent("kept-file-menu-\(action.lowercased()).json"))
    for name in ["Copy", "Remove"] + (expectsOpen ? ["Open"] : []) {
        try requireClips(menu.items.contains { $0.title == name && $0.isEnabled }, "Missing menu action: \(name)")
    }
    guard let index = menu.items.firstIndex(where: { $0.title == action && $0.isEnabled }) else {
        throw NSError(
            domain: "ClipsLayout", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing menu action \(action)"])
    }
    try beforeAction()
    menu.performActionForItem(at: index)
}

#if CLIPS_PREVIEW_REGRESSION
    // Sample actual SwiftUI pixels, not accessibility labels or a model-only preview choice.
    @MainActor
    func previewPixels(_ url: URL, box: NSRect) throws -> (variance: Double, ink: Int, color: Int) {
        let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url))!
        let scale = Double(bitmap.pixelsWide) / 180
        var sum = 0.0, squared = 0.0, count = 0.0
        var ink = 0, color = 0
        for y in Int(box.minY * scale)..<Int(box.maxY * scale) {
            for x in Int(box.minX * scale)..<Int(box.maxX * scale) {
                let c = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                let r = Double(c.redComponent), g = Double(c.greenComponent), b = Double(c.blueComponent)
                let luma = (r + g + b) / 3
                sum += luma; squared += luma * luma; count += 1
                if luma < 0.7 { ink += 1 }
                if max(r, max(g, b)) - min(r, min(g, b)) > 0.3 { color += 1 }
            }
        }
        return (squared / count - pow(sum / count, 2), ink, color)
    }

    @MainActor
    func checkPreviews(window: NSWindow, services: Services, store: PlannerStore, out: URL) async throws {
        let fixtures = out.appendingPathComponent("fixtures")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        func file(_ name: String, _ data: Data) throws -> URL {
            let url = fixtures.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
        let words = "Trail notes\nMeet beside the footbridge.\nBring a map and water.\nCaf\u{00e9} stop after the walk."
        let text = try file("Trail notes.txt", Data(words.utf8))
        let binary = try file("Map data.bin", Data([0, 255, 128, 0, 42]))
        let exact = try file("At limit.txt", Data(repeating: 65, count: 64 * 1024))
        let large = try file("Too large.txt", Data(repeating: 65, count: 64 * 1024 + 1))
        let invalid = try file("Invalid UTF8.txt", Data([255, 254, 128]))
        let empty = try file("Empty notes.txt", Data(" \n\t".utf8))
        let disguised = try file("Binary text.txt", Data([65, 0, 66]))
        let other = try file("Not plain text.bin", Data(words.utf8))
        guard ClipPreview.readText(at: text) == words, ClipPreview.readText(at: exact)?.count == 4096,
            [large, invalid, empty, disguised, other, fixtures, fixtures.appendingPathComponent("Missing.txt")]
                .allSatisfy({ ClipPreview.readText(at: $0) == nil })
        else {
            throw NSError(
                domain: "ClipPreview", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "UTF-8/type/64 KiB boundary policy failed"])
        }
        let blank = NSImage(size: NSSize(width: 132, height: 92), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let real = NSImage(size: NSSize(width: 132, height: 92), flipped: false) { rect in
            NSColor.blue.setFill(); rect.fill()
            NSColor.yellow.setFill(); NSRect(x: 0, y: 0, width: 66, height: 92).fill(); return true
        }
        let cases: [(String, AnyView)] = [
            ("empty-tile", AnyView(Color.white.opacity(0.92).frame(width: 132, height: 92))),
            ("inline-text", AnyView(ClipPreview(content: .text(words), thumbnail: nil))),
            ("text-file", AnyView(ClipPreview(content: .file(text), thumbnail: nil))),
            ("blank-thumbnail", AnyView(ClipPreview(content: .file(text), thumbnail: blank))),
            ("binary-file", AnyView(ClipPreview(content: .file(binary), thumbnail: nil))),
            ("oversized-file", AnyView(ClipPreview(content: .file(large), thumbnail: nil))),
            ("invalid-utf8", AnyView(ClipPreview(content: .file(invalid), thumbnail: nil))),
            ("empty-file", AnyView(ClipPreview(content: .file(empty), thumbnail: nil))),
            ("real-thumbnail", AnyView(ClipPreview(content: .file(text), thumbnail: real))),
        ]
        var checks: [[String: Any]] = []
        var baselines: [String: Double] = [:]
        var inlineVariances: [String: Double] = [:]
        let previewSize = NSSize(width: 180, height: 140)
        for (appearance, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            for (name, root) in cases {
                let view = installClipsFixture(
                    root.environment(\.colorScheme, scheme)
                        .padding(24).background(Color.black), in: window, size: previewSize)
                await settleClips()
                let filename = "preview-\(appearance)-\(name).png"
                let url = out.appendingPathComponent(filename)
                try capture(view, size: previewSize, to: url)
                let pixels = try previewPixels(url, box: NSRect(x: 30, y: 30, width: 120, height: 80))
                let icon = try previewPixels(url, box: NSRect(x: 70, y: 38, width: 40, height: 35))
                if name == "empty-tile" { baselines[appearance] = pixels.variance }
                if name == "inline-text" { inlineVariances[appearance] = pixels.variance }
                let baseline = baselines[appearance]!
                var passed = name == "empty-tile" || (pixels.variance > baseline + 0.002 && pixels.ink > 20)
                if ["text-file", "blank-thumbnail"].contains(name) {
                    passed = passed && abs(pixels.variance - inlineVariances[appearance]!) < 0.000001
                }
                if ["binary-file", "oversized-file", "invalid-utf8", "empty-file"].contains(name) {
                    passed = passed && icon.ink > 20
                }
                if name == "real-thumbnail" { passed = passed && pixels.color > 100 }
                checks.append([
                    "file": filename, "variance": pixels.variance, "emptyTileVariance": baseline,
                    "inkPixels": pixels.ink, "iconInkPixels": icon.ink, "colorPixels": pixels.color,
                    "passed": passed,
                ])
            }
        }
        try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("preview-check.json"))
        guard checks.allSatisfy({ $0["passed"] as? Bool == true }) else {
            throw NSError(
                domain: "ClipPreview", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Preview pixel gate failed; see preview-check.json"])
        }
        // Also capture the production page after a temporary file has really been kept by ClipsService.
        try requireClips(services.clips.clips.isEmpty, "Preview starts from the cleared UI state")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data(words.utf8).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        services.clips.add(.file(temp), source: "dropped")
        guard let kept = services.clips.clips.first, let origin = kept.origin, origin == temp,
            case .file(let keptURL) = kept.content, keptURL != temp, ClipPreview.readText(at: keptURL) == words
        else {
            throw NSError(
                domain: "ClipPreview", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Kept text fixture was not copied into the vault"])
        }
        let pageSize = NSSize(width: 820, height: 360)
        let page = installClipsFixture(
            ClipsPage().environmentObject(store).environmentObject(services)
                .environment(\.accessibilityEnabled, true)
                .environment(\.colorScheme, .dark).padding(24).background(Color.black),
            in: window, size: pageSize)
        await settleClips()
        let beforePin = services.clips.clips
        try clipsMenuAction("Pin", title: kept.title, host: page, expectsOpen: true, out: out) {
            try requireClips(
                services.clips.clips.map(\.id) == beforePin.map(\.id)
                    && services.clips.clips.map(\.pinned) == beforePin.map(\.pinned),
                "Opening the Pin menu changed the clips")
        }
        await settleClips()
        try requireClips(services.clips.clips.first?.pinned == true, "Native Pin must pin the kept file")
        try capture(page, size: pageSize, to: out.appendingPathComponent("kept-file.png"))
        let beforeUnpin = services.clips.clips
        try clipsMenuAction("Unpin", title: kept.title, host: page, expectsOpen: true, out: out) {
            try requireClips(
                services.clips.clips.map(\.id) == beforeUnpin.map(\.id)
                    && services.clips.clips.map(\.pinned) == beforeUnpin.map(\.pinned),
                "Opening the Unpin menu changed the clips")
        }
        await settleClips()
        try requireClips(services.clips.clips.first?.pinned == false, "Native Unpin must unpin the kept file")
        let beforeRemove = services.clips.clips
        try clipsMenuAction("Remove", title: kept.title, host: page, expectsOpen: true, out: out) {
            try requireClips(
                services.clips.clips.map(\.id) == beforeRemove.map(\.id)
                    && services.clips.clips.map(\.pinned) == beforeRemove.map(\.pinned),
                "Opening the Remove menu changed the clips")
        }
        await settleClips()
        try requireClips(services.clips.clips.isEmpty, "Native Remove must remove the kept file")
        try pressClips("Undo", in: page)
        await settleClips()
        try requireClips(services.clips.clips.first?.id == kept.id, "Native Undo must restore the same kept file")
        print(
            "Preview pixel gates: \(checks.count) passed, including UTF-8 limits, real kept file, binary icon and blank Quick Look fallback."
        )
    }
#endif

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
        "clips: Tab reaches the clip actions menu",
        "clips: Space opens the native clip actions menu",
        "clips: Escape closes the clip actions menu",
        "clips: focus returns to the clip actions menu after Escape",
        "clips: cancelling the clip actions menu never pins or removes",
        "clips: arrow keys and Return choose Copy in the actions menu",
        "clips: focus returns to the clip actions menu after choosing Copy",
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
        let file = PlannerFile(url: directory.appendingPathComponent("clips-keyboard-\(UUID()).json"))
        let store = PlannerStore(file: file, watching: false)
        store.updatePrefs {
            $0.welcomeCompleted = true
            $0.catchCopies = false
            $0.catchScreenshots = false
            $0.remindersSync = false
        }
        let pasteboard = ClipsKeyboardPasteboard()
        let clips = ClipsService(store: store, pasteboard: pasteboard, monitoring: false)
        clips.add(.text("Keyboard clip one"), source: "dropped")
        clips.add(.text("Keyboard clip two"), source: "dropped")
        guard clips.clips.count == 2, let first = clips.clips.first(where: { $0.title == "Keyboard clip one" })
        else { throw ClipsKeyboardFailure(assertion: "clips fixture", detail: "expected two clips") }
        let destinations = ClipsKeyboardDestinations()
        let (window, _) = clipsKeyboardWindow(
            "Keyboard Clips",
            ClipsKeyboardHarness(destinations: destinations) {
                ClipsBody(clips: clips).environmentObject(store)
                    .environment(\.accessibilityEnabled, true).environment(\.colorScheme, .dark)
                    .padding(24).background(Color.black)
                    .frame(width: 820, height: 360)
            }, size: NSSize(width: 836, height: 406))
        defer { window.close() }
        await settleClips()
        try run.require(window.makeFirstResponder(destinations.before), "clips fixture", "no starting field")
        try run.require(
            window.isKeyWindow && destinations.before.currentEditor() === window.firstResponder,
            "clips fixture", "starting field must own the key window's native editor")
        func fingerprint() -> [String] { clips.clips.map { "\($0.id) \($0.pinned)" } }
        let before = fingerprint()

        let copyLabel = AppL10n.format("Copy %@", first.title)
        try await clipsTabUntil(window, copyLabel, run: run, assertion: clipsKeyboardAssertions[9])
        if !run.breaks(clipsKeyboardAssertions[10]) { try await clipsKey(window, 49, " ") }
        let copied: [String] = pasteboard.writes.map {
            if case .text(let text) = $0 { return text }
            return "non-text"
        }
        try run.require(copied == ["Keyboard clip one"], clipsKeyboardAssertions[10], "writes \(copied)")
        if run.breaks(clipsKeyboardAssertions[11]) { _ = window.makeFirstResponder(destinations.before) }
        await clipsKeySettle()
        try run.require(
            clipsIsFocused(window, copyLabel), clipsKeyboardAssertions[11], "focused \(clipsFocusedNames(window))")

        let actionsID = "clips.actions.\(first.id)"
        try await clipsTabUntil(window, actionsID, run: run, assertion: clipsKeyboardAssertions[12])
        let cancel = try await clipsOpenMenuByKey(
            window, plan: run.breaks(clipsKeyboardAssertions[14]) ? .nothing : .escape,
            withholdSpace: run.breaks(clipsKeyboardAssertions[13]))
        run.record("clips menu items: \(cancel.items)")
        try run.require(
            cancel.menu != nil && cancel.items.contains(AppL10n.text("Copy"))
                && cancel.items.contains(AppL10n.text("Remove")),
            clipsKeyboardAssertions[13], "items \(cancel.items)")
        try run.require(
            cancel.endedBeforeDeadline && !cancel.cancelledAtDeadline, clipsKeyboardAssertions[14],
            "menu stayed open until the probe deadline")
        if run.breaks(clipsKeyboardAssertions[15]) { _ = window.makeFirstResponder(destinations.before) }
        await clipsKeySettle()
        try run.require(
            clipsIsFocused(window, actionsID), clipsKeyboardAssertions[15], "focused \(clipsFocusedNames(window))")
        if run.breaks(clipsKeyboardAssertions[16]) { clips.togglePin(first.id) }
        try run.require(
            fingerprint() == before && pasteboard.writes.count == 1, clipsKeyboardAssertions[16],
            "clips \(fingerprint()) writes \(pasteboard.writes.count)")

        let choose = try await clipsOpenMenuByKey(
            window, plan: run.breaks(clipsKeyboardAssertions[17]) ? .escape : .choose(AppL10n.text("Copy")),
            withholdSpace: false)
        try run.require(
            choose.endedBeforeDeadline && pasteboard.writes.count == 2 && fingerprint() == before,
            clipsKeyboardAssertions[17], "items \(choose.items) writes \(pasteboard.writes.count)")
        if run.breaks(clipsKeyboardAssertions[18]) { _ = window.makeFirstResponder(destinations.before) }
        await clipsKeySettle()
        try run.require(
            clipsIsFocused(window, actionsID), clipsKeyboardAssertions[18], "focused \(clipsFocusedNames(window))")
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
            // Keyboard child: its own fixtures only, never the layout window or the shared store.
            Task { @MainActor in await runClipsKeyboardChild(out: out) }
            app.run()
        }
    #endif
    let store = PlannerStore()
    let services = Services(store: store)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 820, height: 360),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.backgroundColor = .black
    window.center()
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    DispatchQueue.main.async {
        Task { @MainActor in
            do {
                try checkClipsControlMatching()
                try checkClipsGeometryMatching()
                try checkClipsRopeMatching()
                var captures: [[String: Any]] = []
                // Start with the regression width; both widths retain all four states.
                for width in [640, 820] {
                    for (appearance, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
                        let services = Services(store: store)
                        let size = NSSize(width: width, height: 360)
                        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
                        let view = installClipsFixture(
                            ClipsPage()
                                .environmentObject(store).environmentObject(services)
                                .environment(\.accessibilityEnabled, true)
                                .environment(\.colorScheme, scheme)
                                .padding(24).background(Color.black), in: window, size: size)
                        await settleClips()
                        for state in ["empty", "one", "populated", "cleared"] {
                            switch state {
                            case "one": services.clips.add(.text("Notes for the trail map"), source: "dropped")
                            case "populated":
                                for text in [
                                    "https://example.org/trails", "Pick up a spare notebook",
                                    "Sketch the balcony layout",
                                ] {
                                    services.clips.add(.text(text), source: "dropped")
                                }
                            case "cleared":
                                let ids = services.clips.clips.map(\.id)
                                try pressClips("Remove unpinned", in: view)
                                await settleClips()
                                try requireClips(services.clips.clips.isEmpty, "Remove unpinned did not empty the line")
                                let undo = try clipsFrame(clipsControl("Undo", in: view), in: view)
                                try requireClips(
                                    undo.height >= 28 && view.bounds.insetBy(dx: 24, dy: 24).contains(undo),
                                    "Undo target must be inside the card and at least 28pt high")
                                try capture(
                                    view, size: size, to: out.appendingPathComponent("\(appearance)-\(width)-undo.png"))
                                try pressClips("Undo", in: view)
                                await settleClips()
                                try requireClips(
                                    services.clips.clips.map(\.id) == ids, "Undo changed the clip identities/order")
                                try pressClips("Remove unpinned", in: view)
                            default: break
                            }
                            await settleClips()
                            let name = "\(appearance)-\(width)-\(state).png"
                            let url = out.appendingPathComponent(name)
                            try capture(view, size: size, to: url)
                            try writeClipsAccessibility(
                                view, to: url.deletingPathExtension().appendingPathExtension("ax.json"))
                            let toolbar = try checkClipsToolbar(url, host: view)
                            if state == "populated" { try await checkClipsScrolling(host: view) }
                            captures.append([
                                "file": name, "width": width, "height": 360,
                                "appearance": appearance, "state": state,
                                "clipCount": services.clips.clips.count,
                                "card": [24, 24, width - 24, 336],
                                "rope_y": toolbar["ropeY"]!, "toolbar": toolbar,
                            ])
                        }
                    }
                }
                try JSONSerialization.data(withJSONObject: captures, options: [.prettyPrinted, .sortedKeys])
                    .write(to: out.appendingPathComponent("captures.json"))
                #if CLIPS_PREVIEW_REGRESSION
                    try await checkPreviews(window: window, services: services, store: store, out: out)
                    try await checkCaptureToggleInteractions(window: window, out: out)
                    try checkClipsKeyboard()
                #endif
                print(
                    "Clips snapshots: \(captures.count). Actual ClipsPage + ClipsService; fixed dark tile in both appearances."
                )
                exit(0)
            } catch {
                fputs("Clips snapshot failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }
    withExtendedLifetime((window, store, services)) { app.run() }
}
