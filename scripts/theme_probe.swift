// CI-only entry point: render production views and color pairs, without changing system preferences.
import AppKit
import ApplicationServices
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
    var rows = [
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
        ColorPair(name: "text/card", foreground: Theme.text, background: surface, minimum: 4.5),
        ColorPair(name: "secondary/card", foreground: Theme.secondary, background: surface, minimum: 4.5),
    ]
    let backgrounds: [(String, Color)] =
        light
        ? [("card", surface), ("alternate", strong), ("window", Color(hex: "#F5F5F5")), ("form", .white)]
        : [("card", surface), ("alternate", strong), ("shell", .black)]
    let inks: [(String, Color)] = [
        ("text", Theme.text), ("secondary", Theme.secondary),
        ("tertiary", Theme.tertiary), ("success", Theme.success), ("danger", Theme.danger),
        ("warning", Theme.warning), ("info", Theme.info),
    ]
    for (label, bg) in backgrounds {
        for (name, ink) in inks {
            rows.append(ColorPair(name: "\(name)/\(label) readable", foreground: ink, background: bg, minimum: 4.5))
        }
    }
    for (state, fill) in [
        ("rest", Theme.fill), ("hover", Theme.fillStrong),
        ("pressed", Theme.fillPressed), ("selected", Theme.selectedPill),
    ] {
        for (name, ink) in inks.prefix(3) {
            rows.append(ColorPair(name: "\(name)/control-\(state)", foreground: ink, background: fill, minimum: 4.5))
        }
    }
    for (label, bg) in [("card", surface), ("alternate", strong)] {
        for (state, fill) in [("rest", Theme.inputFill), ("focused", Theme.inputFillFocused)] {
            rows.append(
                ColorPair(
                    name: "input-text/\(label)-\(state)", foreground: Theme.text,
                    background: fill.composited(over: bg), minimum: 4.5))
        }
        rows.append(ColorPair(name: "focus-ring/\(label)", foreground: Theme.info, background: bg, minimum: 3))
    }
    rows.append(
        ColorPair(name: "prominent-label", foreground: Theme.onAccent, background: Theme.prominent, minimum: 4.5))
    rows.append(
        ColorPair(
            name: "planned-chart/lavender", foreground: Theme.chartPlanned, background: Theme.lavender, minimum: 3))
    rows.append(
        ColorPair(
            name: "completed-chart/lavender", foreground: Theme.chartCompleted, background: Theme.lavender, minimum: 3))
    rows.append(
        ColorPair(
            name: "completed-chart/planned-chart", foreground: Theme.chartCompleted,
            background: Theme.chartPlanned, minimum: 3))
    if light {
        rows.append(
            ColorPair(name: "focus-progress/track", foreground: Theme.text, background: Theme.chartPlanned, minimum: 3))
    }
    return rows
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
    host.safeAreaRegions = []
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    window.contentView = host
    window.orderFrontRegardless()
    host.layoutSubtreeIfNeeded()
    return (window, host)
}

@MainActor func save(_ view: NSView, _ url: URL, scale: Int? = nil) {
    view.layoutSubtreeIfNeeded()
    let bitmap: NSBitmapImageRep
    if let scale {
        bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * scale,
            pixelsHigh: Int(view.bounds.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = view.bounds.size
    } else {
        bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
    try! png.write(to: url)
}

@MainActor func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}

@MainActor func click(_ point: CGPoint, in host: NSView, window: NSWindow) {
    let local = CGPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y)
    let location = host.convert(local, to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        NSApp.sendEvent(event)
    }
}

@MainActor func key(_ code: UInt16, _ character: String, in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        let event = NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: character,
            charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
        NSApp.sendEvent(event)
    }
}

@MainActor final class ControlFixture: ObservableObject {
    @Published var state = "rest"
    @Published var selection = 0
    @Published var renderFocusRing = false
    var actions = 0
    var frames: [String: CGRect] = [:]
    var increasedContrast: Bool?
    var destinations: [String: NSTextField] = [:]

    func destinationHasFocus(_ name: String, in window: NSWindow) -> Bool {
        guard let field = destinations[name], let editor = field.currentEditor() else { return false }
        return window.isKeyWindow && window.firstResponder === editor
    }

    func focusedControl(in window: NSWindow) -> String {
        guard window.isKeyWindow else { return "no-key-window" }
        for name in ["before-pages", "after-pages"] where destinationHasFocus(name, in: window) {
            return name
        }
        // Query native accessibility focus, not the value requested through FocusState.
        let owners: [NSObject] = [NSApp, window, window.contentView, window.firstResponder].compactMap { $0 }
        var observed = "other: \(String(describing: window.firstResponder))"
        for owner in owners {
            let selector = NSSelectorFromString("accessibilityFocusedUIElement")
            guard owner.responds(to: selector),
                let node = owner.perform(selector)?.takeUnretainedValue() as? NSObject
            else { continue }
            @MainActor func attribute(_ name: String) -> String? {
                let selector = NSSelectorFromString(name)
                guard node.responds(to: selector) else { return nil }
                return node.perform(selector)?.takeUnretainedValue() as? String
            }
            let identifier = attribute("accessibilityIdentifier")
            let label = attribute("accessibilityLabel")
            let role = attribute("accessibilityRole")
            if role == "AXButton" && (identifier == "theme-continue" || label == "Continue") {
                return "continue"
            }
            observed = "other: \(role ?? "no-role") / \(label ?? "no-label") / \(identifier ?? "no-id")"
        }
        return observed
    }
}

func wakeControlAccessibility() async {
    await Task.detached {
        let app = AXUIElementCreateApplication(getpid())
        var value: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        for window in (value as? [AXUIElement]) ?? [] {
            var children: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children)
        }
    }.value
}

@MainActor func focusContinue(_ fixture: ControlFixture, in window: NSWindow) async {
    require(window.makeFirstResponder(fixture.destinations["before-pages"]!), "Native focus starts before pages")
    for _ in 0..<8 {
        key(48, "\t", in: window, modifiers: .shift)
        try? await Task.sleep(nanoseconds: 100_000_000)
        if fixture.focusedControl(in: window) == "continue" { return }
    }
    // Keyboard traversal is environment-dependent; the caller records the observed identity.
}

@MainActor func controlAttribute(_ node: NSObject, _ name: String) -> Any? {
    let selector = NSSelectorFromString(name)
    return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
}

@MainActor func controlNodes(_ root: NSObject) -> [NSObject] {
    var seen = Set<ObjectIdentifier>()
    @MainActor func walk(_ node: NSObject, _ depth: Int) -> [NSObject] {
        guard depth < 60, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
        return [node]
            + ((controlAttribute(node, "accessibilityChildren") as? [NSObject]) ?? [])
            .flatMap { walk($0, depth + 1) }
    }
    return walk(root, 0)
}

@MainActor func pressContinue(in root: NSView) {
    guard
        let node = controlNodes(root).first(where: {
            controlAttribute($0, "accessibilityRole") as? String == "AXButton"
                && controlAttribute($0, "accessibilityLabel") as? String == "Continue"
                && controlAttribute($0, "accessibilityIdentifier") as? String == "theme-continue"
        })
    else {
        require(false, "Continue exposes its AX button role, label and identifier"); return
    }
    let selector = NSSelectorFromString("accessibilityPerformPress")
    guard node.responds(to: selector), let implementation = node.method(for: selector) else {
        require(false, "Continue supports AX press"); return
    }
    typealias Press = @convention(c) (AnyObject, Selector) -> Bool
    require(unsafeBitCast(implementation, to: Press.self)(node, selector), "Continue accepts AX press")
}

// Real text fields make both ends of the key-view loop testable even when
// ordinary buttons are excluded by the host's keyboard-navigation setting.
struct FocusDestination: NSViewRepresentable {
    let name: String
    let fixture: ControlFixture

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: "")
        field.placeholderString = name == "before-pages" ? "Before pages" : "After pages"
        field.setAccessibilityIdentifier(name)
        field.font = .systemFont(ofSize: 12)
        fixture.destinations[name] = field
        return field
    }

    func updateNSView(_ view: NSTextField, context: Context) {}
}

struct ControlBounds: ViewModifier {
    let fixture: ControlFixture
    let name: String
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { fixture.frames[name] = geometry.frame(in: .named("gallery")) }
                    .onChange(of: geometry.frame(in: .named("gallery"))) { _, frame in fixture.frames[name] = frame }
            })
    }
}

struct ControlGallery: View {
    @ObservedObject var fixture: ControlFixture
    let tone: CardTone
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Primary task title").font(Theme.title).foregroundStyle(Theme.text)
            Text("Secondary supporting label").font(Theme.body).foregroundStyle(Theme.secondary)
            Text("Tertiary hint stays readable").font(Theme.meta).foregroundStyle(Theme.tertiary)
            HStack(spacing: 14) {
                StatusLabel(title: "Done", tone: .success)
                StatusLabel(title: "Error", tone: .danger)
                StatusLabel(title: "High", tone: .warning)
                StatusLabel(title: "Info", tone: .info)
            }.font(Theme.meta)
            HStack(spacing: 24) {
                Button {
                    fixture.actions += 1
                } label: {
                    Text("Continue")
                }
                .buttonStyle(PillStyle(prominent: true))
                .accessibilityIdentifier("theme-continue")
                .disabled(fixture.state == "disabled")
                // Exercise the production ring path without pretending the runner gave
                // the button keyboard focus. This override exists only in the fixture.
                .overlay {
                    if fixture.renderFocusRing {
                        ControlFocusRing(shape: Capsule(), focused: true)
                    }
                }
                .modifier(ControlBounds(fixture: fixture, name: "continue"))
                Button("Unavailable") { fixture.actions += 1 }
                    .buttonStyle(PillStyle(disabledReason: "Choose a task first."))
                    .disabled(true)
                    .modifier(ControlBounds(fixture: fixture, name: "unavailable"))
                GlassButton(symbol: "play.fill", help: "Start focus", action: { fixture.actions += 1 })
                    .disabled(fixture.state == "disabled")
            }
            HStack(spacing: 14) {
                FocusDestination(name: "before-pages", fixture: fixture).frame(width: 80, height: 24)
                SegmentPills(items: [(0, "Today"), (1, "Week"), (2, "Insights")], selection: $fixture.selection)
                    .modifier(ControlBounds(fixture: fixture, name: "tabs"))
                FocusDestination(name: "after-pages", fixture: fixture).frame(width: 80, height: 24)
            }
            Text("Choose a task first.").font(Theme.meta).foregroundStyle(Theme.secondary)
        }
        .frame(width: 480, height: 270, alignment: .topLeading)
        .card(tone)
        .padding(10)
        .background(Color.black)
        .coordinateSpace(name: "gallery")
        .onAppear { fixture.increasedContrast = contrast == .increased }
        .onChange(of: contrast) { _, value in fixture.increasedContrast = value == .increased }
    }
}

MainActor.assumeIsolated {
    require(
        UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") == 3,
        "Probe process explicitly enables keyboard navigation")
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
        var controls: [[String: Any]] = []
        var nativeContrastAppearance: [[String: Any]] = []
        var keyboardVerified = false
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
                        Text("Aa Medium 08").font(Theme.title).foregroundStyle(rows[i].foreground)
                            .frame(width: 200, alignment: .leading).offset(x: 140)
                    }.frame(width: 360, height: 30)
                }
            }.environment(\.colorScheme, light ? .light : .dark)
            let (swatchWindow, swatchHost) = render(
                swatches, size: CGSize(width: 360, height: rows.count * 30), appearance: appearance)
            try? await Task.sleep(nanoseconds: 400_000_000)
            save(swatchHost, output.appendingPathComponent("\(mode)-swatches.png"), scale: 1)
            save(swatchHost, output.appendingPathComponent("\(mode)-swatches-2x.png"), scale: 2)
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
            for increased in [false, true] {
                for (toneName, tone) in [("sage", CardTone.tasks), ("lavender", .timer), ("tile", .tile)] {
                    let fixture = ControlFixture()
                    let gallery = ControlGallery(fixture: fixture, tone: tone)
                    let contrastAppearance = NSAppearance(
                        named: increased
                            ? (light ? .accessibilityHighContrastAqua : .accessibilityHighContrastDarkAqua)
                            : (light ? .aqua : .darkAqua))!
                    let (galleryWindow, galleryHost) = render(
                        gallery, size: CGSize(width: 528, height: 318), appearance: contrastAppearance)
                    galleryWindow.makeKeyAndOrderFront(nil)
                    app.activate(ignoringOtherApps: true)
                    await wakeControlAccessibility()
                    for state in ["rest", "focused", "disabled"] {
                        fixture.state = state
                        fixture.renderFocusRing = false
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        if state == "focused" {
                            await focusContinue(fixture, in: galleryWindow)
                        } else {
                            require(
                                galleryWindow.makeFirstResponder(fixture.destinations["before-pages"]!),
                                "The before-pages field accepts native focus")
                            try? await Task.sleep(nanoseconds: 100_000_000)
                        }
                        let focusedControl = fixture.focusedControl(in: galleryWindow)
                        let renderedRing = state == "focused" && focusedControl != "continue"
                        fixture.renderFocusRing = renderedRing
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        save(
                            galleryHost,
                            output.appendingPathComponent("focus-diagnostic-\(mode)-\(toneName)-\(state).png"))
                        if state != "focused" {
                            require(
                                focusedControl == "before-pages",
                                "\(state) capture focus identity: \(focusedControl)")
                        }
                        // Record SwiftUI's observation separately from the native window appearance.
                        let contrastEnvironment =
                            fixture.increasedContrast.map { $0 ? "increased" : "standard" } ?? "unobserved"
                        let effectiveAppearance = galleryWindow.effectiveAppearance.name.rawValue
                        if state == "rest" {
                            nativeContrastAppearance.append([
                                "appearance": mode, "increased": increased, "tone": toneName,
                                "contrast_environment": contrastEnvironment,
                                "effective_appearance": effectiveAppearance,
                            ])
                        }
                        for scale in [1, 2] {
                            let name =
                                "\(mode)-\(increased ? "increased" : "standard")-\(toneName)-\(state)-\(scale)x.png"
                            save(galleryHost, output.appendingPathComponent(name), scale: scale)
                            controls.append([
                                "file": name, "tone": toneName, "state": state, "scale": scale,
                                "appearance": mode, "increased": increased, "focused_control": focusedControl,
                                "contrast_environment": contrastEnvironment,
                                "effective_appearance": effectiveAppearance,
                                "focus_evidence": renderedRing ? "rendered-ring" : "native-focus",
                                "focus_ring_target": state == "focused" ? "continue" : "none",
                                "keyboardActivation": "unverified-on-this-runner",
                                "frames": fixture.frames.mapValues { [$0.minX, $0.minY, $0.width, $0.height] },
                            ])
                        }
                    }
                    if light && !increased && toneName == "sage" {
                        let button = fixture.frames["continue"]!
                        click(CGPoint(x: button.midX, y: button.midY), in: galleryHost, window: galleryWindow)
                        require(fixture.actions == 0, "disabled control ignores clicks")
                        fixture.state = "rest"
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        click(CGPoint(x: button.midX, y: button.midY), in: galleryHost, window: galleryWindow)
                        require(fixture.actions == 1, "enabled control invokes its real action")
                        await wakeControlAccessibility()
                        let actionsBeforeAX = fixture.actions
                        pressContinue(in: galleryHost)
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        require(fixture.actions == actionsBeforeAX + 1, "AX press invokes Continue exactly once")
                        await focusContinue(fixture, in: galleryWindow)
                        if fixture.focusedControl(in: galleryWindow) == "continue" {
                            let actionsBeforeSpace = fixture.actions
                            key(49, " ", in: galleryWindow)
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            keyboardVerified = fixture.actions == actionsBeforeSpace + 1
                        }
                    }
                    galleryWindow.close()
                }
            }

        }
        try! JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("swatches.json"))
        try! JSONSerialization.data(withJSONObject: controls, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("controls.json"))
        let metrics: [String: Any] = [
            "keyboardActivation": keyboardVerified ? "verified-in-process-Tab-Space" : "unverified-on-this-runner",
            "nativeContrastAppearance": nativeContrastAppearance,
            "activation": "real-own-process-AX-press-no-model-fallback",
            "screenshots": "own-window-cacheDisplay-not-compositor",
        ]
        try! JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("results.json"))
        print("Keyboard activation: \(metrics["keyboardActivation"]!)")
        print("Native contrast appearance: \(metrics["nativeContrastAppearance"]!)")
        exit(0)
    }
    app.run()
}
