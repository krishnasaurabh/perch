// CI-only entry point: render production views and color pairs, without changing system preferences.
import AppKit
import PlannerCore
#if canImport(PerchApp)
    @testable import PerchApp
    import PerchUI
    import PerchMCP
#endif
import SwiftUI

struct ColorPair {
    let name: String
    let foreground: Color
    let background: Color
    let minimum: Double
}

@MainActor func pairs(_ light: Bool) -> [ColorPair] {
    let surface = light ? Theme.sage : Theme.tile
    let strong = light ? Theme.lavender : Theme.tileStrong
    return [
        ColorPair(
            name: "card silhouette/body", foreground: light ? Theme.sage : Theme.cardStroke, background: .black,
            minimum: 3),
        ColorPair(
            name: "alternate silhouette/body", foreground: light ? Theme.lavender : Theme.cardStroke,
            background: .black, minimum: 3),
        ColorPair(name: "cardStroke/card", foreground: Theme.cardStroke, background: surface, minimum: 3),
        ColorPair(name: "cardStroke/alternate", foreground: Theme.cardStroke, background: strong, minimum: 3),
        ColorPair(name: "inputStroke/card", foreground: Theme.inputStroke, background: surface, minimum: 3),
        ColorPair(
            name: "inputStroke/resting", foreground: Theme.inputStroke,
            background: Theme.inputFill.composited(over: surface), minimum: 3),
        ColorPair(
            name: "inputStroke/focused", foreground: Theme.inputStroke,
            background: Theme.inputFillFocused.composited(over: surface), minimum: 3),
        ColorPair(
            name: "inputStroke/miniComposer", foreground: Theme.inputStroke,
            background: Color.white.opacity(0.05).composited(over: surface), minimum: 3),
        ColorPair(
            name: "inputStroke/alternateFocused", foreground: Theme.inputStroke,
            background: Theme.inputFillFocused.composited(over: strong), minimum: 3),
        ColorPair(name: "rope/card", foreground: Theme.rope, background: surface, minimum: 3),
        ColorPair(name: "rope/alternate", foreground: Theme.rope, background: strong, minimum: 3),
        ColorPair(name: "priority/card", foreground: Theme.priority(.high), background: surface, minimum: 3),
        ColorPair(name: "priority/alternate", foreground: Theme.priority(.high), background: strong, minimum: 3),
        ColorPair(
            name: "selected/card (informational)", foreground: Theme.selectedPill, background: surface, minimum: 0),
        ColorPair(name: "text/card (unchanged)", foreground: Theme.text, background: surface, minimum: 4.5),
        ColorPair(name: "secondary/card (unchanged)", foreground: Theme.secondary, background: surface, minimum: 4.5),
    ]
}

// Compose in sRGB exactly as SwiftUI draws the two translucent field fills.
extension Color {
    @MainActor func composited(over color: Color) -> Color {
        let fg = NSColor(self).usingColorSpace(.sRGB)!
        let bg = NSColor(color).usingColorSpace(.sRGB)!
        let a = fg.alphaComponent
        return Color(
            .sRGB, red: fg.redComponent * a + bg.redComponent * (1 - a),
            green: fg.greenComponent * a + bg.greenComponent * (1 - a),
            blue: fg.blueComponent * a + bg.blueComponent * (1 - a), opacity: 1)
    }
}

@MainActor func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance? = nil) -> (
    NSWindow, NSHostingView<V>
) {
    let host = NSHostingView(rootView: view)
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    window.contentView = host
    window.orderFrontRegardless()
    host.layoutSubtreeIfNeeded()
    return (window, host)
}

@MainActor func save(_ view: NSView, _ url: URL) {
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No bitmap") }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
    try! png.write(to: url)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THEME_PROBE_OUTPUT"]!)
    Task { @MainActor in
        let store = PlannerStore()
        let services = Services(store: store)
        guard
            let seeded = store.apply({
                try $0.addTasks(
                    [
                        "Sort the field notes !high", "Sketch a reading corner", "Refill the sketch pencils",
                        "Label the spare sketchbook",
                    ], on: .day(store.today))
            }),
            seeded.count == 4, seeded.contains(where: { $0.priority == .high })
        else { fatalError("Priority fixture missing") }
        // Keep the real segmented filter visible after empty-Completed suppression.
        _ = store.apply { try $0.complete(seeded.last!.id) }
        let geometry = NotchGeometry(
            screen: .init(
                frame: CGRect(x: 0, y: 0, width: 1024, height: 768),
                visibleFrame: CGRect(x: 0, y: 0, width: 1024, height: 744)))
        var manifest: [[String: Any]] = []
        for light in [true, false] {
            let mode = light ? "light" : "dark"
            let appearance = NSAppearance(named: light ? .aqua : .darkAqua)!
            app.appearance = appearance
            var rows: [ColorPair] = []
            appearance.performAsCurrentDrawingAppearance { rows = pairs(light) }
            let swatches = VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { i in
                    ZStack(alignment: .leading) {
                        rows[i].background
                        rows[i].foreground.frame(width: 60)
                    }.frame(width: 120, height: 30)
                }
            }.environment(\.colorScheme, light ? .light : .dark)
            let (swatchWindow, swatchHost) = render(
                swatches, size: CGSize(width: 120, height: rows.count * 30), appearance: appearance)
            try? await Task.sleep(nanoseconds: 400_000_000)
            save(swatchHost, output.appendingPathComponent("\(mode)-swatches.png"))
            manifest.append(["appearance": mode, "rows": rows.map { ["name": $0.name, "minimum": $0.minimum] }])
            swatchWindow.close()

            let model = NotchModel(motionPolicy: MotionPolicy(reduceMotion: true))
            model.screenID = 1
            model.geometry = geometry
            let screen = NotchScreenState(id: 1, geometry: geometry)
            let root = NotchRootView().environmentObject(store).environmentObject(services)
                .environmentObject(model).environmentObject(screen)
                .environment(\.motionPolicyOverride, MotionPolicy(reduceMotion: true))
            let (window, host) = render(root, size: geometry.window.size)
            for page in [NotchPage.home, .week] {
                model.open(page: page, pinned: true)
                try? await Task.sleep(nanoseconds: 700_000_000)
                save(host, output.appendingPathComponent("\(mode)-\(page.rawValue).png"))
                if page == .home {
                    window.makeKeyAndOrderFront(nil)
                    app.activate(ignoringOtherApps: true)
                    model.captureFocusRequest = UUID()
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    save(host, output.appendingPathComponent("\(mode)-home-focused.png"))
                    model.captureFocusRequest = nil
                }
            }
            window.close()
            let settings = SettingsView().environmentObject(store).environmentObject(services)
                .environment(\.colorScheme, light ? .light : .dark)
            let (settingsWindow, settingsHost) = render(
                settings, size: CGSize(width: 620, height: 560), appearance: appearance)
            settingsWindow.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            try? await Task.sleep(nanoseconds: 700_000_000)
            save(settingsHost, output.appendingPathComponent("\(mode)-settings.png"))
            settingsWindow.close()
        }
        try! JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("swatches.json"))
        exit(0)
    }
    app.run()
}
