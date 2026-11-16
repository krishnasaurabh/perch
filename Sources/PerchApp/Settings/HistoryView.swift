import AppKit
import PerchUI
import SwiftUI

/// The shared dashboard supplies the window header and sheet.
struct HistoryView: View {
    static func subtitle(store: PlannerStore) -> String {
        AppL10n.text("Everything you finished, day by day.")
    }

    var body: some View { DashboardPane { HistoryList() } }

    #if DEBUG || PERCH_TESTING
        static func preview(_ filter: HistoryModel.Filter, app: AppDelegate) {
            HistoryPreviewState.shared.filter = filter
            DashboardWindow.show(store: app.store, tab: .history)
        }
    #endif
}

/// Give the scroll document its own semantic root, as the dashboard's tab strip
/// does. Otherwise macOS can paint SwiftUI descendants without publishing their
/// accessibility children through the enclosing scroll host.
struct DashboardPane<Content: View>: NSViewControllerRepresentable {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.self) private var environment
    @ViewBuilder var content: () -> Content

    func makeNSViewController(context: Context) -> NSHostingController<DashboardPaneRoot<Content>> {
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = [.intrinsicContentSize]
        return controller
    }

    func updateNSViewController(_ controller: NSHostingController<DashboardPaneRoot<Content>>, context: Context) {
        // Update values, not identity: the list keeps its search, expansion,
        // rename and popover state when the store or appearance publishes.
        controller.rootView = root
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsViewController: NSHostingController<DashboardPaneRoot<Content>>,
        context: Context
    ) -> CGSize? {
        let width: CGFloat = proposal.width ?? CGFloat(Theme.Size.todayWidth.value)
        let size = nsViewController.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }

    private var root: DashboardPaneRoot<Content> {
        DashboardPaneRoot(content: content(), store: store, environment: environment)
    }
}

/// Token-based paint and a single native owner for page focus, AX and actions.
/// A SwiftUI focus proxy cannot reliably be entered from the search field's
/// native key loop across the nested hosting boundary.
/// Keep the painted label out of AX; only its overlaid native control acts.
private struct DashboardPaneActionPaint: ViewModifier {
    let title: String
    let identifier: String
    let selected: Bool?
    let radius: CGFloat
    let surface: DesignTokens.Surface
    let action: () -> Void
    @State private var focused = false
    @State private var pressed = false

    func body(content: Content) -> some View {
        content
            .overlay(FocusRing(shape: RoundedRectangle(cornerRadius: radius), focused: focused, surface: surface))
            .perchControlFeedback(pressed: pressed)
            .accessibilityHidden(true)
            .overlay {
                DashboardPaneActionTarget(
                    title: title, identifier: identifier, selected: selected, action: action,
                    focusChanged: { focused = $0 }, pressChanged: { pressed = $0 })
            }
    }
}

extension View {
    func dashboardPaneAction(
        _ title: String, identifier: String, selected: Bool? = nil,
        radius: CGFloat = Theme.Size.segmentRadius.value, surface: DesignTokens.Surface = .paper,
        action: @escaping () -> Void
    ) -> some View {
        modifier(
            DashboardPaneActionPaint(
                title: title, identifier: identifier, selected: selected, radius: radius,
                surface: surface, action: action))
    }
}

/// A page action with the same token sizing as the shared button, but with a
/// native focus owner for the dashboard's cross-host key loop.
struct DashboardPaneButton: View {
    let title: String
    let identifier: String
    let accessibilityTitle: String?
    var kind: PerchButtonKind = .quiet
    var size: PerchButtonSize = .small
    var surface: DesignTokens.Surface = .paper
    let action: () -> Void

    init(
        _ title: String, identifier: String, accessibilityTitle: String? = nil, kind: PerchButtonKind = .quiet,
        size: PerchButtonSize = .small, surface: DesignTokens.Surface = .paper,
        action: @escaping () -> Void
    ) {
        self.title = title; self.identifier = identifier; self.accessibilityTitle = accessibilityTitle; self.kind = kind
        self.size = size; self.surface = surface; self.action = action
    }

    var body: some View {
        Text(AppL10n.text(title)).perchFont(.button)
            .foregroundStyle(kind == .main ? Theme.onBrand : Theme.ink2)
            .padding(.horizontal, Theme.Size.buttonSidePadding.value)
            .padding(.vertical, Theme.Size.stepCheckboxRadius.value)
            .frame(minWidth: Theme.Size.minimumTarget.value, minHeight: size.height)
            .background(Capsule().fill(kind == .main ? Theme.brandFill : .clear))
            .dashboardPaneAction(
                accessibilityTitle ?? AppL10n.text(title), identifier: identifier, radius: size.height / 2,
                surface: surface, action: action)
    }
}

struct DashboardPaneActionTarget: NSViewRepresentable {
    let title: String
    let identifier: String
    var selected: Bool? = nil
    let action: () -> Void
    let focusChanged: (Bool) -> Void
    let pressChanged: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled

    func makeNSView(context: Context) -> DashboardPaneActionView { DashboardPaneActionView() }

    func updateNSView(_ view: DashboardPaneActionView, context: Context) {
        view.setAccessibilityLabel(title)
        view.setAccessibilityIdentifier(identifier)
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.selected = selected
        view.isEnabled = enabled
        view.onAction = action
        view.focusChanged = focusChanged
        view.pressChanged = pressChanged
        if !enabled, view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
    }
}

final class DashboardPaneActionView: NSControl {
    var selected: Bool?
    var onAction: () -> Void = {}
    var focusChanged: (Bool) -> Void = { _ in }
    var pressChanged: (Bool) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            DashboardKeyLoop.install(in: window)
        }
    }
    override func becomeFirstResponder() -> Bool {
        guard acceptsFirstResponder, super.becomeFirstResponder() else { return false }
        updateFocusPaint()
        NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
        return true
    }
    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        updateFocusPaint()
        return true
    }
    private func updateFocusPaint() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusChanged(self.isAccessibilityFocused())
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 {
            guard !event.isARepeat,
                event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                event.window === window, window?.isKeyWindow == true,
                window?.firstResponder === self, acceptsFirstResponder
            else { return }
            onAction()
        } else if event.keyCode == 48,
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        {
            if event.modifierFlags.contains(.shift) {
                window?.selectPreviousKeyView(self)
            } else {
                window?.selectNextKeyView(self)
            }
        } else {
            super.keyDown(with: event)
        }
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode != 49 { super.keyUp(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        guard acceptsFirstResponder else { return }
        window?.makeFirstResponder(self)
        pressChanged(true)
        defer { pressChanged(false) }
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                if acceptsFirstResponder, bounds.contains(convert(next.locationInWindow, from: nil)) { onAction() }
                break
            }
        }
    }
    override func isAccessibilityFocused() -> Bool {
        acceptsFirstResponder && window?.isKeyWindow == true && window?.firstResponder === self
    }
    override var accessibilityFocusedUIElement: Any? { isAccessibilityFocused() ? self : nil }
    override func accessibilityValue() -> Any? {
        selected.map { AppL10n.text($0 ? "Selected" : "Not selected") }
    }
    override func isAccessibilitySelected() -> Bool { selected == true }
    override func accessibilityPerformPress() -> Bool {
        guard window != nil, acceptsFirstResponder else { return false }
        onAction()
        return true
    }
}

struct DashboardPaneRoot<Content: View>: View {
    let content: Content
    let store: PlannerStore
    let environment: EnvironmentValues

    var body: some View {
        content
            .environmentObject(store)
            .environment(\.accessibilityEnabled, true)
            // Whole-environment forwarding must be outermost, so it cannot
            // overwrite the explicit store and semantic activation above.
            .environment(\.self, environment)
            // The outer dashboard owns scrolling. Measure the ideal document
            // height at its actual width, including wrapped/enlarged text.
            .fixedSize(horizontal: false, vertical: true)
    }
}
