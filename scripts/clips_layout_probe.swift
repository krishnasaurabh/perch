// Temporary CI entry point only. Renders the actual ClipsPage; never touches the clipboard.
import AppKit
import SwiftUI
import Vision
import PlannerCore
#if canImport(PerchApp)
    @testable import PerchApp
    import PerchUI
    import PerchMCP
#endif

@MainActor
func capture(_ view: NSView, to url: URL) throws {
    view.layoutSubtreeIfNeeded()
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
func clipsNodes(_ root: NSObject) -> [NSObject] {
    var seen = Set<ObjectIdentifier>()
    @MainActor func walk(_ node: NSObject) -> [NSObject] {
        guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
        let children = (clipsAttribute(node, "accessibilityChildren") as? [NSObject]) ?? []
        let contents = (clipsAttribute(node, "accessibilityContents") as? [NSObject]) ?? []
        let subviews = (node as? NSView)?.subviews ?? []
        return [node] + (children + contents + subviews).flatMap { walk($0) }
    }
    return walk(root)
}

@MainActor
func clipsControl(_ title: String, in host: NSView) throws -> NSObject {
    let matches = clipsNodes(host).filter { node in
        let role = clipsAttribute(node, "accessibilityRole") as? String
        return ["AXButton", "AXCheckBox", "AXSwitch", "AXPopUpButton", "AXMenuButton"].contains(role ?? "")
            && ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains {
                clipsAttribute(node, $0) as? String == title
            }
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
        throw NSError(domain: "ClipsLayout", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing enabled state: \(title)"])
    }
    typealias Enabled = @convention(c) (AnyObject, Selector) -> Bool
    try requireClips(unsafeBitCast(enabledMethod, to: Enabled.self)(node, enabledSelector), "Disabled control: \(title)")
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
    try requireClips(abs(after.minY - footer.minY) < 0.5 && abs(after.minX - footer.minX) < 0.5,
                     "Footer moved with the clips")
    scroll.contentView.scroll(to: before)
    scroll.reflectScrolledClipView(scroll.contentView)
    await settleClips()
}

// Recognize each complete label on ONE rendered line. Joining OCR lines (or checking AX
// labels alone) would wrongly accept the old "Add / screenshot / s" narrow layout.
@MainActor
func checkClipsToolbar(_ url: URL, host: NSView) throws -> [String: Any] {
    let names = ["Add screenshots", "Add copied items", "Remove unpinned"]
    var frames: [NSRect] = []
    for name in names {
        frames.append(try clipsFrame(clipsControl(name, in: host), in: host))
    }
    let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url))!
    let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
    // NSHostingView uses flipped coordinates; image coordinates are always top-down.
    let bottom = frames.map { host.isFlipped ? $0.maxY : host.bounds.height - $0.minY }.max()!
    let box = CGRect(x: 24 * scale, y: 24 * scale,
                     width: (host.bounds.width - 48) * scale, height: (bottom - 24) * scale)
    let image = bitmap.cgImage!.cropping(to: box)!
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = false
    request.minimumTextHeight = 0.01
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    try requireClips(names.allSatisfy { name in lines.contains { $0.contains(name) } },
                     "Toolbar labels must be whole single lines at \(Int(host.bounds.width))pt; OCR: \(lines)")
    for (name, frame) in zip(names, frames) {
        try requireClips(host.bounds.insetBy(dx: 24, dy: 24).contains(frame), "Control outside card: \(name)")
        try requireClips(frame.height >= 28, "Control target below 28pt: \(name), \(frame)")
    }
    for i in frames.indices {
        for j in frames.indices where j > i {
            try requireClips(!frames[i].intersects(frames[j]), "Toolbar controls overlap")
        }
    }

    // Locate the actual rope's left end in the captured pixels BELOW the measured
    // toolbar. Only translate the scanner's existing 7 x 34pt ROI; do not widen it.
    let firstY = Int(ceil((bottom + Theme.gutter) * scale))
    let lastY = min(bitmap.pixelsHigh, firstY + Int(ClipsLineLayout.bandHeight * scale))
    @MainActor func ropeRow(in image: NSBitmapImageRep) -> Int? {
        for y in firstY..<lastY {
            let ink = (Int(43 * scale)..<Int(50 * scale)).filter { x in
                guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                let rgb = [c.redComponent, c.greenComponent, c.blueComponent].map { $0 * 255 }
                return rgb.min()! > 45 && rgb.max()! - rgb.min()! < 5
            }.count
            if ink > 0 { return y }
        }
        return nil
    }
    let ropeY = ropeRow(in: bitmap)
    try requireClips(ropeY != nil, "No rope below toolbar in actual capture")
    // Negative control for anchor discovery itself: erase only the rope strip
    // in an in-memory copy, leaving other header/content pixels untouched.
    let noRope = NSBitmapImageRep(data: try Data(contentsOf: url))!
    for y in max(firstY, ropeY! - Int(2 * scale))..<min(lastY, ropeY! + Int(14 * scale)) {
        for x in Int(43 * scale)..<Int(50 * scale) { noRope.setColor(.black, atX: x, y: y) }
    }
    try requireClips(ropeRow(in: noRope) == nil, "Rope anchor detector accepted a rope-less capture")
    return ["toolbarBottom": bottom, "toolbarLines": lines, "ropeY": CGFloat(ropeY!) / scale]
}

// Observe the menu opened by the actual More control, not reconstructed actions.
@MainActor
final class ClipsMenuTracker: NSObject {
    var menu: NSMenu?
    private var tracking: NSMenu?
    private var timer: Timer?
    private let deadline = ProcessInfo.processInfo.systemUptime + 3
    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(began(_:)),
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
func clipsMenuAction(_ action: String, title: String, host: NSView, expectsOpen: Bool) throws {
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
    for name in ["Copy", "Remove"] + (expectsOpen ? ["Open"] : []) {
        try requireClips(menu.items.contains { $0.title == name && $0.isEnabled }, "Missing menu action: \(name)")
    }
    guard let index = menu.items.firstIndex(where: { $0.title == action && $0.isEnabled }) else {
        throw NSError(domain: "ClipsLayout", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing menu action \(action)"])
    }
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
        window.setContentSize(NSSize(width: 180, height: 140))
        for (appearance, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            for (name, root) in cases {
                let view = NSHostingView(
                    rootView: root.environment(\.colorScheme, scheme)
                        .padding(24).background(Color.black))
                window.contentView = view
                await settleClips()
                let filename = "preview-\(appearance)-\(name).png"
                let url = out.appendingPathComponent(filename)
                try capture(view, to: url)
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
        window.setContentSize(NSSize(width: 820, height: 360))
        let page = NSHostingView(
            rootView: ClipsPage().environmentObject(store).environmentObject(services)
                .environment(\.accessibilityEnabled, true)
                .environment(\.colorScheme, .dark).padding(24).background(Color.black))
        window.contentView = page
        await settleClips()
        try clipsMenuAction("Pin", title: kept.title, host: page, expectsOpen: true)
        await settleClips()
        try requireClips(services.clips.clips.first?.pinned == true, "Native Pin must pin the kept file")
        try capture(page, to: out.appendingPathComponent("kept-file.png"))
        try clipsMenuAction("Unpin", title: kept.title, host: page, expectsOpen: true)
        await settleClips()
        try requireClips(services.clips.clips.first?.pinned == false, "Native Unpin must unpin the kept file")
        try clipsMenuAction("Remove", title: kept.title, host: page, expectsOpen: true)
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

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLIPS_OUTPUT"]!)
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
                var captures: [[String: Any]] = []
                // Start with the regression width; both widths retain all four states.
                for width in [640, 820] {
                    for (appearance, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
                        let services = Services(store: store)
                        window.setContentSize(NSSize(width: width, height: 360))
                        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
                        let view = NSHostingView(
                            rootView: ClipsPage()
                                .environmentObject(store).environmentObject(services)
                                .environment(\.accessibilityEnabled, true)
                                .environment(\.colorScheme, scheme)
                                .padding(24).background(Color.black))
                        window.contentView = view
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
                                try requireClips(undo.height >= 28 && view.bounds.insetBy(dx: 24, dy: 24).contains(undo),
                                                 "Undo target must be inside the card and at least 28pt high")
                                try capture(view, to: out.appendingPathComponent("\(appearance)-\(width)-undo.png"))
                                try pressClips("Undo", in: view)
                                await settleClips()
                                try requireClips(services.clips.clips.map(\.id) == ids, "Undo changed the clip identities/order")
                                try pressClips("Remove unpinned", in: view)
                            default: break
                            }
                            await settleClips()
                            let name = "\(appearance)-\(width)-\(state).png"
                            let url = out.appendingPathComponent(name)
                            try capture(view, to: url)
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
