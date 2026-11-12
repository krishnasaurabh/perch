import AppKit
import SwiftUI

private final class UndoRoutingWindow: NSWindow {
    var onUndo: ((Bool) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.charactersIgnoringModifiers == "z", flags.contains(.command), !(firstResponder is NSTextView),
            let onUndo
        {
            onUndo(flags.contains(.shift))
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Regular windows (Settings, Dashboard, Welcome) hosted outside the notch panel.
@MainActor
enum WindowHost {
    static var windows: [String: NSWindow] = [:]

    static func show<V: View>(
        _ id: String, title: String, size: CGSize, onUndo: ((Bool) -> Void)? = nil,
        @ViewBuilder content: () -> V
    ) {
        if let w = windows[id] {
            if let onUndo { (w as? UndoRoutingWindow)?.onUndo = onUndo }
            NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return
        }
        let w = UndoRoutingWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.onUndo = onUndo
        w.title = AppL10n.text(title)
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
