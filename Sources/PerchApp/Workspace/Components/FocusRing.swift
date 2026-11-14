import AppKit
import PerchUI
import SwiftUI

/// One local, non-consuming monitor for the app; pointer focus never paints a keyboard ring.
@MainActor
final class ControlInputModality: ObservableObject {
    static let shared = ControlInputModality()
    @Published private(set) var keyboard = true
    private var monitor: Any?

    init(observeEvents: Bool = true) {
        if observeEvents {
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                MainActor.assumeIsolated { self?.receive(event.type) }
                return event
            }
        }
    }

    func receive(_ type: NSEvent.EventType) {
        switch type {
        case .keyDown: keyboard = true
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: keyboard = false
        default: break
        }
    }

    // The observing instance is app-lifetime shared state, not a per-row monitor.
}

/// Stroke expands outside the control without consuming layout or pointer events.
struct FocusRing<S: InsettableShape>: View {
    let shape: S
    let focused: Bool
    var surface: DesignTokens.Surface = .paper
    @ObservedObject private var modality = ControlInputModality.shared

    var body: some View {
        if focused && modality.keyboard {
            shape.inset(by: -DesignTokens.Size.focusGap.value - DesignTokens.Size.focusWidth.value / 2)
                .stroke(Theme.foreground(.focusRing, on: surface), lineWidth: DesignTokens.Size.focusWidth.value)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
