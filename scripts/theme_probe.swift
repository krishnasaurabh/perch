// CI-only entry point: render production views and color pairs, without changing system preferences.
import AppKit
import ApplicationServices
@testable import PlannerCore
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

// Names the fixture an assertion belongs to in the printed output, so a rendered
// focus-ring gallery result can never be read as a production-page result.
@MainActor enum ProbeScope {
    static var label: String?
}

@MainActor func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    let name = ProbeScope.label.map { "\($0): \(message)" } ?? message
    guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
    print("PASS: \(name)")
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
            print("Rendered focus-ring gallery (fixture, not a production page): \(mode)")
            ProbeScope.label = "rendered focus-ring gallery"
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
                                "gallery": "rendered-focus-ring-gallery",
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
            ProbeScope.label = nil

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
            "focusRingGallery": "rendered-focus-ring-gallery: fixture ring pixels, not native keyboard focus",
        ]
        try! JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("results.json"))
        print("Keyboard activation: \(metrics["keyboardActivation"]!)")
        print("Native contrast appearance: \(metrics["nativeContrastAppearance"]!)")
        print("Focus-ring gallery: \(metrics["focusRingGallery"]!)")
        await measureEffectiveStates(
            store: store, services: services, detailsTask: seeded[0].id, geometry: geometry, output: output)
        exit(Measured.failed.isEmpty ? 0 : 1)
    }
    app.run()
}

// MARK: - Effective enlarged-type and contrast states, measured per production page

// Measured-state assertions collect every red before exiting, so one run reports all failures.
@MainActor enum Measured {
    static var failed: [String] = []
    static var rows: [[String: Any]] = []
    static func check(_ condition: Bool, _ message: String) {
        if condition {
            print("PASS: measured state: \(message)")
        } else {
            failed.append(message)
            fputs("FAIL: measured state: \(message)\n", stderr)
        }
    }
}

struct PageState {
    let name: String
    let enlarged: Bool
    let increased: Bool
}

let pageStates = [
    PageState(name: "standard", enlarged: false, increased: false),
    PageState(name: "enlarged-type", enlarged: true, increased: false),
    PageState(name: "increased-contrast", enlarged: false, increased: true),
    PageState(name: "enlarged-increased", enlarged: true, increased: true),
]

/// Observes the contrast SwiftUI actually resolved for the hosted page.
@MainActor final class ContrastObservation: ObservableObject {
    var value: ColorSchemeContrast?
    var typeSize: DynamicTypeSize?
}

struct ContrastReader: View {
    let observation: ContrastObservation
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear {
                observation.value = contrast
                observation.typeSize = typeSize
            }
            .onChange(of: contrast) { _, value in observation.value = value }
            .onChange(of: typeSize) { _, value in observation.typeSize = value }
    }
}

struct PageInk {
    let background: [Int]
    let inkPixels: Int
    let inkRows: Int
    let maxRatio: Double
}

func pageLuminance(_ c: [Int]) -> Double {
    let v = c.prefix(3).map { x -> Double in
        let s = Double(x) / 255
        return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2]
}

func pageContrast(_ a: [Int], _ b: [Int]) -> Double {
    let (x, y) = (pageLuminance(a), pageLuminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

/// Rendered-pixel measurement: dominant background, then pixels at >= 3:1 against it.
@MainActor func measureInk(_ view: NSView) -> PageInk {
    view.layoutSubtreeIfNeeded()
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    var counts: [Int: Int] = [:]
    let (w, h) = (bitmap.pixelsWide, bitmap.pixelsHigh)
    func rgb(_ x: Int, _ y: Int) -> [Int] {
        var p = [Int](repeating: 0, count: 4)
        bitmap.getPixel(&p, atX: x, y: y)
        return Array(p.prefix(3))
    }
    for y in stride(from: 0, to: h, by: 2) {
        for x in stride(from: 0, to: w, by: 2) {
            let c = rgb(x, y)
            counts[(c[0] << 16) | (c[1] << 8) | c[2], default: 0] += 1
        }
    }
    let key = counts.max { $0.value < $1.value }?.key ?? 0
    let background = [(key >> 16) & 255, (key >> 8) & 255, key & 255]
    var ink = 0
    var rows = 0
    var best = 1.0
    for y in 0..<h {
        var rowInk = false
        for x in 0..<w {
            let ratio = pageContrast(rgb(x, y), background)
            if ratio >= 3 {
                ink += 1
                rowInk = true
            }
            best = max(best, ratio)
        }
        if rowInk { rows += 1 }
    }
    return PageInk(background: background, inkPixels: ink, inkRows: rows, maxRatio: best)
}

/// In-process AX walk (the same NSAccessibility path the gallery's AX press uses).
@MainActor func pageNodes(_ host: NSView) -> [NSObject] {
    var seen = Set<ObjectIdentifier>()
    return (controlNodes(host) + host.subviews.flatMap({ controlNodes($0) })).filter {
        seen.insert(ObjectIdentifier($0)).inserted
    }
}

@MainActor func nodeFrame(_ node: NSObject) -> CGRect? {
    guard node.responds(to: NSSelectorFromString("accessibilityFrame")),
        let value = node.value(forKey: "accessibilityFrame") as? NSValue
    else { return nil }
    return value.rectValue
}

@MainActor func pageTextFrames(_ host: NSView, window: NSWindow) -> [(String, CGRect)] {
    var result: [(String, CGRect)] = []
    for node in pageNodes(host) where controlAttribute(node, "accessibilityRole") as? String == "AXStaticText" {
        guard let frame = nodeFrame(node) else { continue }
        guard frame.width > 0, frame.height > 0 else { continue }
        let name =
            (controlAttribute(node, "accessibilityLabel") as? String)
            ?? (controlAttribute(node, "accessibilityValue") as? String) ?? ""
        result.append((name, frame))
    }
    return result
}

/// Every node whose accessibility label is a permission state title (a StatusLabel).
@MainActor func statusLabelFrames(_ host: NSView) -> [CGRect] {
    let titles = Set(PermissionState.allCases.map(\.title))
    var frames: [CGRect] = []
    for node in pageNodes(host) {
        guard let label = controlAttribute(node, "accessibilityLabel") as? String, titles.contains(label),
            let frame = nodeFrame(node), frame.height > 0
        else { continue }
        frames.append(frame)
    }
    return frames
}

@MainActor func settle(_ nanoseconds: UInt64 = 700_000_000) async {
    try? await Task.sleep(nanoseconds: nanoseconds)
}

@MainActor func firstTable(_ view: NSView) -> NSTableView? {
    if let table = view as? NSTableView { return table }
    for child in view.subviews { if let table = firstTable(child) { return table } }
    return nil
}

@MainActor func measureEffectiveStates(
    store: PlannerStore, services: Services, detailsTask: UUID, geometry: NotchGeometry, output: URL
) async {
    let app = NSApplication.shared
    let appearance = NSAppearance(named: .aqua)!
    app.appearance = appearance
    let model = NotchModel(motionPolicy: MotionPolicy(reduceMotion: true))
    model.screenID = 1
    model.geometry = geometry
    // Historical fixture for Dashboard History, written to the synthetic store only.
    _ = try? store.file.mutate { planner in
        planner.tasks.append(
            PlanTask(title: "Measured history task", day: store.today.adding(days: -2), done: true))
    }
    store.reloadFromDisk(external: false)
    services.clips.add(.text("Measured clip text"), source: "copied")

    typealias Page = (name: String, size: CGSize, settingsPane: Int?, view: AnyView)
    let settings = AnyView(SettingsView().environmentObject(store).environmentObject(services))
    var pages: [Page] = SettingsView.Pane.allCases.enumerated().map { index, pane -> Page in
        ("settings-\(pane.rawValue)", CGSize(width: 620, height: 560), index, settings)
    }
    for tab in DashboardView.Tab.allCases {
        pages.append(
            (
                "dashboard-\(tab.rawValue)", CGSize(width: 900, height: 640), nil,
                AnyView(DashboardView(tab: tab).environmentObject(store))
            ))
    }
    pages.append(
        (
            "welcome", CGSize(width: 560, height: 520), nil,
            AnyView(WelcomeView(done: {}).environmentObject(store).environmentObject(services))
        ))
    pages.append(
        (
            "details", CGSize(width: 460, height: 600), nil,
            AnyView(TaskDetailsSheet(taskID: detailsTask).environmentObject(store))
        ))
    pages.append(
        (
            "details-removed", CGSize(width: 460, height: 300), nil,
            AnyView(TaskDetailsSheet(taskID: UUID()).environmentObject(store))
        ))
    pages.append(
        (
            "week", CGSize(width: 820, height: 320), nil,
            AnyView(
                WeekPage().environmentObject(store).environmentObject(model).padding(20)
                    .background(Color.black))
        ))
    pages.append(
        (
            "clips", CGSize(width: 820, height: 320), nil,
            AnyView(
                ClipsPage().environmentObject(store).environmentObject(services).padding(20)
                    .background(Color.black))
        ))

    var statusGrowth: [String: (Double, Double)] = [:]
    for page in pages {
        var ink: [String: PageInk] = [:]
        var text: [String: [(String, CGRect)]] = [:]
        for state in pageStates {
            let observation = ContrastObservation()
            // NEGATIVE-CONTROL SITE (type): the enlarged state requests accessibility3.
            let typeSize: DynamicTypeSize = state.enlarged ? .accessibility3 : .large
            // NEGATIVE-CONTROL SITE (contrast): the increased state requests .increased.
            let contrast: ColorSchemeContrast = state.increased ? .increased : .standard
            let root = ZStack(alignment: .topLeading) {
                page.view.accessibilityHidden(true)  // NEGATIVE CONTROL: AX frames removed
                ContrastReader(observation: observation)
            }
            .environment(\.dynamicTypeSize, typeSize)
            .environment(\._colorSchemeContrast, contrast)
            .environment(\.accessibilityEnabled, true)
            let label = "\(page.name) [\(state.name)]"
            let (window, host) = render(root, size: page.size, appearance: appearance)
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            await settle()
            if let pane = page.settingsPane, pane > 0 {
                // Real key events on the native sidebar list; never an AX or model substitute.
                let table = firstTable(host)
                Measured.check(
                    table.map { window.makeFirstResponder($0) } == true,
                    "\(label): the Settings sidebar accepts native keyboard focus")
                print("MEASURED: \(label) sidebar row before keys \(table?.selectedRow ?? -1)")
                for _ in 0..<pane {
                    _ = window  // NEGATIVE CONTROL: no key event sent
                    await settle(250_000_000)
                }
                Measured.check(
                    table?.selectedRow == pane,
                    "\(label): Down Arrow selects the \(page.name) pane (row \(table?.selectedRow ?? -1))")
                await settle()
            }
            await wakeControlAccessibility()
            await settle(250_000_000)
            let measured = measureInk(host)
            let frames = pageTextFrames(host, window: window)
            ink[state.name] = measured
            text[state.name] = frames
            save(host, output.appendingPathComponent("measured-\(page.name)-\(state.name).png"))
            Measured.check(
                measured.inkPixels >= 150, "\(label): rendered page has text ink (\(measured.inkPixels) px)")
            Measured.check(
                measured.maxRatio >= 4.5,
                "\(label): rendered ink reaches 4.5:1 against the page background (\(measured.maxRatio))")
            let content = window.convertToScreen(window.contentLayoutRect)
            Measured.check(
                frames.contains { content.intersects($0.1) },
                "\(label): real AX frames expose on-screen static text (\(frames.count) nodes)")
            let resolvedType = observation.typeSize.map { "\($0)" } ?? "unobserved"
            Measured.check(
                observation.typeSize == typeSize,
                "\(label): SwiftUI resolves the requested type size \(typeSize) (\(resolvedType))")
            let observed = observation.value.map { $0 == .increased ? "increased" : "standard" } ?? "unobserved"
            Measured.check(
                observed == (state.increased ? "increased" : "standard"),
                "\(label): SwiftUI resolves the \(state.increased ? "increased" : "standard") contrast (\(observed))")
            let status = statusLabelFrames(host)
            if !status.isEmpty {
                let tallest = status.map(\.height).max() ?? 0
                var entry = statusGrowth[page.name] ?? (0, 0)
                if state.name == "standard" { entry.0 = tallest }
                if state.name == "enlarged-type" { entry.1 = tallest }
                statusGrowth[page.name] = entry
            }
            Measured.rows.append([
                "page": page.name, "state": state.name, "ink_pixels": measured.inkPixels,
                "ink_rows": measured.inkRows, "max_ratio": measured.maxRatio, "background": measured.background,
                "ax_static_text": frames.count,
                "ax_text_height_total": frames.reduce(0) { $0 + $1.1.height },
                "status_label_heights": status.map(\.height), "contrast_environment": observed,
                "type_size": resolvedType,
                "effective_appearance": window.effectiveAppearance.name.rawValue,
            ])
            window.close()
        }
        // Enlarged type: measured from both rendered ink and real AX frame heights.
        if let base = ink["standard"], let big = ink["enlarged-type"] {
            let baseText = text["standard"]?.reduce(0) { $0 + $1.1.height } ?? 0
            let bigText = text["enlarged-type"]?.reduce(0) { $0 + $1.1.height } ?? 0
            print(
                "MEASURED: \(page.name) enlarged type ink rows \(base.inkRows) -> \(big.inkRows), AX text height \(baseText) -> \(bigText)"
            )
        }
        // Increased contrast must never render less contrast than the standard state.
        if let standard = ink["standard"], let increased = ink["increased-contrast"] {
            Measured.check(
                increased.maxRatio + 0.01 >= standard.maxRatio,
                "\(page.name): increased contrast keeps rendered contrast (\(standard.maxRatio) -> \(increased.maxRatio))"
            )
        }
    }
    // Pages that render a StatusLabel must show the enlarged size in its real AX frame.
    for name in ["welcome", "settings-System"] {
        let (base, big) = statusGrowth[name] ?? (0, 0)
        Measured.check(base > 0, "\(name): a status label's AX frame is measured at the standard size (\(base))")
        Measured.check(
            base > 0 && big >= base * 1.4,
            "\(name): enlarged type grows the status label's real AX frame (\(base) -> \(big))")
    }
    let payload: [String: Any] = ["rows": Measured.rows, "failed": Measured.failed]
    try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("measured-states.json"))
    print("Measured states: \(Measured.rows.count) captures, \(Measured.failed.count) failed")
}
