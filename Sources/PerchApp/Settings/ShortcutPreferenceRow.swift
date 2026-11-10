import AppKit
import PerchUI
import SwiftUI

// MARK: - Global shortcut

/// The shortcut in Settings: shows what is live, records a replacement, and says so when macOS refuses one.
struct ShortcutPreferenceRow: View {
    @State private var shortcut: ShortcutKey = .default
    @State private var recording = false
    @State private var problem: String?

    var body: some View {
        LabeledContent("Shortcut") {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    if recording {
                        ShortcutRecorder(onRecord: choose, onCancel: { recording = false })
                            .frame(width: 104, height: 24)
                        Text("Press the keys you want. Esc cancels.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button {
                            problem = nil; recording = true
                        } label: {
                            Text(shortcut.display)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .frame(minWidth: 64)
                        }
                        .help("Click, then press the keys you want to use")
                        if shortcut != .default {
                            Button("Use ⌥N") { choose(.default) }.buttonStyle(.link)
                        }
                    }
                }
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .onAppear { shortcut = ShortcutStore.load() }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.didFail)) { note in
            // The live hot key kept the old chord; show what is actually registered now.
            recording = false
            shortcut = note.userInfo?["restored"] as? ShortcutKey ?? ShortcutStore.load()
            problem = "macOS wouldn't give up that combination. Kept \(shortcut.display)."
        }
    }

    private func choose(_ key: ShortcutKey) {
        recording = false
        problem = nil
        shortcut = key
        ShortcutStore.save(key)  // the running hot key re-registers on this change, no relaunch
    }
}

/// One key press, captured straight from the window so ⌘ combinations never reach the menu bar.
private final class ShortcutRecorderView: NSView {
    var onRecord: ((ShortcutKey) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 6, yRadius: 6)
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    override func keyDown(with event: NSEvent) { capture(event) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        return capture(event) || super.performKeyEquivalent(with: event)
    }

    /// Escape cancels; anything that isn't a usable chord beeps and keeps listening.
    @discardableResult
    private func capture(_ event: NSEvent) -> Bool {
        if event.keyCode == UInt16(ShortcutKey.escapeKeyCode) { onCancel?(); return true }
        guard let key = ShortcutKey(event: event) else { NSSound.beep(); return true }
        onRecord?(key)
        return true
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let onRecord: (ShortcutKey) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onRecord = onRecord
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.onRecord = onRecord
        view.onCancel = onCancel
        // SwiftUI inserts the view before it has a window; take the keyboard on the next pass.
        DispatchQueue.main.async {
            guard let window = view.window, window.firstResponder !== view else { return }
            window.makeFirstResponder(view)
        }
    }
}
