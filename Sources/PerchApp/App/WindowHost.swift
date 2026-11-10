import AppKit
import SwiftUI

/// Regular windows (Settings, Dashboard, Welcome) hosted outside the notch panel.
@MainActor
enum WindowHost {
    static var windows: [String: NSWindow] = [:]

    static func show<V: View>(_ id: String, title: String, size: CGSize, @ViewBuilder content: () -> V) {
        if let w = windows[id] { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: content())
        w.center()
        windows[id] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            Task { @MainActor in windows[id] = nil }
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
