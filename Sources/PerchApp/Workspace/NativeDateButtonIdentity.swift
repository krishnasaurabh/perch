import AppKit
import SwiftUI

/// Publishes the label on the existing native button without replacing its style,
/// target/action, focus handling or layout. The anchor belongs inside the label so
/// it can identify its owner by ancestry, never by a sibling's position or title.
struct NativeDateButtonIdentity: NSViewRepresentable {
    let identifier: String
    let label: String

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.setAccessibilityElement(false)
        view.identifierValue = identifier
        view.labelValue = label
        return view
    }

    func updateNSView(_ nsView: Anchor, context: Context) {
        nsView.identifierValue = identifier
        nsView.labelValue = label
        nsView.publish()
        // SwiftUI can update the native button after updating its label.
        DispatchQueue.main.async { [weak nsView] in nsView?.publish() }
    }

    final class Anchor: NSView {
        var identifierValue = ""
        var labelValue = ""

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            publish()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            publish()
        }

        override func layout() {
            super.layout()
            publish()
        }

        func publish() {
            var ancestor = superview
            while let view = ancestor {
                if let button = view as? NSButton {
                    button.setAccessibilityElement(true)
                    button.setAccessibilityRole(.button)
                    button.setAccessibilityIdentifier(identifierValue)
                    button.setAccessibilityLabel(labelValue)
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
