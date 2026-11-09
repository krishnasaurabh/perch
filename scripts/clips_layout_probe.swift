// Temporary CI entry point only. Renders the actual ClipsPage; never touches the clipboard.
import AppKit
import SwiftUI
import PlannerCore

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

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLIPS_OUTPUT"]!)
    let store = PlannerStore()
    let services = Services(store: store)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 360),
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
                        let view = NSHostingView(rootView: ClipsPage()
                            .environmentObject(store).environmentObject(services)
                            .environment(\.colorScheme, scheme)
                            .padding(24).background(Color.black))
                        window.contentView = view
                        await settleClips()
                        for state in ["empty", "one", "populated", "cleared"] {
                            switch state {
                            case "one": services.clips.add(.text("Notes for the trail map"), source: "dropped")
                            case "populated":
                                for text in ["https://example.org/trails", "Pick up a spare notebook", "Sketch the balcony layout"] {
                                    services.clips.add(.text(text), source: "dropped")
                                }
                            case "cleared": services.clips.clearUnpinned()
                            default: break
                            }
                            await settleClips()
                            let name = "\(appearance)-\(width)-\(state).png"
                            try capture(view, to: out.appendingPathComponent(name))
                            captures.append(["file": name, "width": width, "height": 360,
                                             "appearance": appearance, "state": state,
                                             "clipCount": services.clips.clips.count,
                                             "card": [24, 24, width - 24, 336]])
                        }
                    }
                }
                try JSONSerialization.data(withJSONObject: captures, options: [.prettyPrinted, .sortedKeys])
                    .write(to: out.appendingPathComponent("captures.json"))
                print("Clips snapshots: \(captures.count). Actual ClipsPage + ClipsService; fixed dark tile in both appearances.")
                exit(0)
            } catch {
                fputs("Clips snapshot failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }
    withExtendedLifetime((window, store, services)) { app.run() }
}
