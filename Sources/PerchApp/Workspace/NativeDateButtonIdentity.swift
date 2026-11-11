import AppKit
import SwiftUI

/// Bounds native accessibility annotation to one unchanged SwiftUI button.
/// The separate host keeps the button's identity available inside a scroll host;
/// its content still owns drawing and keyboard focus. The host forwards AX presses
/// only when SwiftUI does not materialize a single native button.
struct NativeDateButtonIdentity<Content: View>: NSViewRepresentable {
    let identifier: String
    let label: String
    let action: () -> Void
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
        nsView.enabledValue = environment.isEnabled
        nsView.action = action
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
        var enabledValue = true
        var action: (() -> Void)?
        private var ownsAccessibility = true
        private weak var nativeOwner: NSButton?

        override func isAccessibilityElement() -> Bool { ownsAccessibility }
        override func accessibilityRole() -> NSAccessibility.Role? {
            ownsAccessibility ? .button : super.accessibilityRole()
        }
        override func accessibilityIdentifier() -> String {
            ownsAccessibility ? identifierValue : ""
        }
        override func accessibilityLabel() -> String? {
            ownsAccessibility ? labelValue : nil
        }
        override func isAccessibilityEnabled() -> Bool {
            ownsAccessibility ? enabledValue : super.isAccessibilityEnabled()
        }
        override func accessibilityChildren() -> [Any]? {
            ownsAccessibility ? [] : super.accessibilityChildren()
        }
        override func accessibilityPerformPress() -> Bool {
            guard ownsAccessibility, enabledValue, let action else { return false }
            action()
            return true
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
            @MainActor func buttons(in view: NSView) -> [NSButton] {
                if let button = view as? NSButton { return [button] }
                return view.subviews.flatMap { buttons(in: $0) }
            }
            // When SwiftUI draws the button itself, the host is its semantic leaf.
            // Otherwise annotate the sole native button, never an arbitrary child.
            let candidates = buttons(in: self)
            let owner = candidates.count == 1 ? candidates.first : nil
            if nativeOwner !== owner {
                nativeOwner?.setAccessibilityIdentifier(nil)
                nativeOwner?.setAccessibilityLabel(nil)
            }
            nativeOwner = owner
            ownsAccessibility = owner == nil
            if let owner {
                owner.setAccessibilityElement(true)
                owner.setAccessibilityRole(.button)
                owner.setAccessibilityIdentifier(identifierValue)
                owner.setAccessibilityLabel(labelValue)
            }
        }
    }
}
