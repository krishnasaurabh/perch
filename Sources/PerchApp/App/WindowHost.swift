import AppKit
import SwiftUI

private final class UndoRoutingWindow: NSWindow {
    var onUndo: ((Bool) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if firstResponder is KeysShortcutInputOwner { return super.performKeyEquivalent(with: event) }
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
    private static var closeObservers: [String: NSObjectProtocol] = [:]

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
        w.contentView = NSHostingView(rootView: content().previewEnvironment())
        w.center()
        windows[id] = w
        closeObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: w, queue: .main
        ) { [weak w] _ in
            MainActor.assumeIsolated {
                guard let w else { return }
                // Retire this identity synchronously. An immediate reopen must
                // create a fresh host, and an old callback must not remove it.
                if windows[id] === w {
                    windows[id] = nil
                    if let observer = closeObservers.removeValue(forKey: id) {
                        NotificationCenter.default.removeObserver(observer)
                    }
                }
                // Keep the window alive beyond AppKit's close dispatch. Detach
                // SwiftUI's hosted/KVO graph while its observed window is still
                // strongly owned, not from inside NSWindow.deinit.
                Task { @MainActor [w] in
                    w.makeFirstResponder(nil)
                    w.initialFirstResponder = nil
                    w.contentView = nil
                    (w as? UndoRoutingWindow)?.onUndo = nil
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
