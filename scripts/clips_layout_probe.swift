// Temporary CI entry point only. Renders the actual ClipsPage; never touches the clipboard.
import AppKit
import SwiftUI
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
        services.clips.clearUnpinned()
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
        services.clips.togglePin(kept.id)
        window.setContentSize(NSSize(width: 820, height: 360))
        let page = NSHostingView(
            rootView: ClipsPage().environmentObject(store).environmentObject(services)
                .environment(\.colorScheme, .dark).padding(24).background(Color.black))
        window.contentView = page
        await settleClips()
        try capture(page, to: out.appendingPathComponent("kept-file.png"))
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
                for width in [820, 640] {
                    for (appearance, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
                        services.clips.clearUnpinned()
                        window.setContentSize(NSSize(width: width, height: 360))
                        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
                        let view = NSHostingView(
                            rootView: ClipsPage()
                                .environmentObject(store).environmentObject(services)
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
                            case "cleared": services.clips.clearUnpinned()
                            default: break
                            }
                            await settleClips()
                            let name = "\(appearance)-\(width)-\(state).png"
                            try capture(view, to: out.appendingPathComponent(name))
                            captures.append([
                                "file": name, "width": width, "height": 360,
                                "appearance": appearance, "state": state,
                                "clipCount": services.clips.clips.count,
                                "card": [24, 24, width - 24, 336],
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
