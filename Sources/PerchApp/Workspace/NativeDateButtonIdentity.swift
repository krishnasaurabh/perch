import AppKit
import SwiftUI

/// Bounds native accessibility annotation to one unchanged SwiftUI button.
/// The separate host keeps the button's identity available inside a scroll host;
/// its content still owns drawing, keyboard focus, enabled state and activation.
struct NativeDateButtonIdentity<Content: View>: NSViewRepresentable {
    let identifier: String
    let label: String
    @ViewBuilder var content: () -> Content
    @Environment(\.self) private var environment

    func makeNSView(context: Context) -> Host {
        let view = Host(rootView: root)
        view.sizingOptions = [.intrinsicContentSize]
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: Host, context: Context) {
        nsView.identifierValue = identifier
        nsView.labelValue = label
        nsView.rootView = root
        nsView.invalidateIntrinsicContentSize()
        nsView.needsLayout = true
        // SwiftUI installs or updates the native child after assigning rootView.
        DispatchQueue.main.async { [weak nsView] in nsView?.publish() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Host, context: Context) -> CGSize? {
        nsView.fittingSize
    }

    private var root: AnyView { AnyView(content().environment(\.self, environment)) }

    final class Host: NSHostingView<AnyView> {
        var identifierValue = ""
        var labelValue = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            publish()
        }

        override func layout() {
            super.layout()
            publish()
        }

        func publish() {
            @MainActor func buttons(in view: NSView) -> [NSButton] {
                if let button = view as? NSButton { return [button] }
                return view.subviews.flatMap { buttons(in: $0) }
            }
            // Never annotate an arbitrary sibling if the content contract changes.
            let candidates = buttons(in: self)
            guard candidates.count == 1, let button = candidates.first else { return }
            button.setAccessibilityElement(true)
            button.setAccessibilityRole(.button)
            button.setAccessibilityIdentifier(identifierValue)
            button.setAccessibilityLabel(labelValue)
        }
    }
}
