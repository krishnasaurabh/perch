import AppKit
import SwiftUI

@MainActor
enum DashboardWindow {
    static let identifier = "dashboard"
    private(set) static var selection: DashboardSelection?

    static func show(store: PlannerStore, tab: DashboardView.Tab = .yourWeek) {
        let state: DashboardSelection
        if WindowHost.windows[identifier] != nil, let selection {
            state = selection
        } else {
            state = DashboardSelection(tab: tab)
            selection = state
        }
        state.tab = tab
        WindowHost.show(
            identifier, title: "Perch",
            size: CGSize(width: Theme.Size.todayWidth.value, height: Theme.Size.stripMaxWidth.value),
            onUndo: { redo in redo ? store.redo() : store.undo() }
        ) {
            DashboardView(selection: state).environmentObject(store).environment(\.accessibilityEnabled, true)
        }
    }

    static func show(store: PlannerStore, model: NotchModel, services: Services) {
        show(store: store)
    }

    /// Replace the old dashboard entry, preserving the caller's Undo and Settings actions.
    /// Each item retains its target for the lifetime of the native menu.
    static func installMenuItems(in menu: NSMenu, open: @escaping () -> Void) {
        guard let old = menu.items.first(where: { $0.title == AppL10n.text("Open Dashboard") }) else { return }
        let insertion = menu.index(of: old)
        menu.removeItem(old)
        for (offset, tab) in DashboardView.Tab.allCases.enumerated() {
            let target = DashboardMenuAction {
                open()
                selection?.tab = tab
            }
            let item = NSMenuItem(
                title: AppL10n.text(tab.windowTitle), action: #selector(DashboardMenuAction.chooseTab(_:)),
                keyEquivalent: "")
            item.target = target
            item.representedObject = target
            menu.insertItem(item, at: insertion + offset)
        }
    }
}

@MainActor
final class DashboardSelection: ObservableObject {
    @Published var tab: DashboardView.Tab {
        didSet {
            guard tab != oldValue else { return }
            tabHost?.selectionDidChange()
        }
    }
    weak var tabHost: DashboardTabsHost?
    init(tab: DashboardView.Tab = .yourWeek) { self.tab = tab }
}

@MainActor
private final class DashboardMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func chooseTab(_ sender: NSMenuItem) { action() }
}

/// One ordinary window. Each tab owns its content and subtitle independently.
struct DashboardView: View {
    @EnvironmentObject var store: PlannerStore
    @StateObject var selection: DashboardSelection

    init(selection: DashboardSelection) { _selection = StateObject(wrappedValue: selection) }
    init(tab: Tab = .yourWeek) { _selection = StateObject(wrappedValue: DashboardSelection(tab: tab)) }

    enum Tab: String, CaseIterable {
        case yourWeek = "This week", history = "History", projects = "Projects"

        var windowTitle: String { self == .yourWeek ? "Your week" : rawValue }
        var heading: String { self == .history ? "Looking back" : windowTitle }
    }

    private var subtitle: String {
        switch selection.tab {
        case .yourWeek: YourWeekView.subtitle(store: store)
        case .history: HistoryView.subtitle(store: store)
        case .projects: ProjectsView.subtitle(store: store)
        }
    }

    var body: some View {
        DotGridSheet(.window) {
            VStack(alignment: .leading, spacing: Theme.Size.cardGap.value) {
                HStack(alignment: .bottom, spacing: SurfaceMetrics.textInset) {
                    VStack(alignment: .leading, spacing: .zero) {
                        Text(AppL10n.text(selection.tab.heading))
                            .perchFont(.windowTitle)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("dashboard-title")
                        Text(subtitle)
                            .perchFont(.body)
                            .foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: .zero)
                    DashboardTabs(selection: selection)
                        .fixedSize()
                }
                .padding(.horizontal, SurfaceMetrics.gap / 2)
                ScrollView {
                    content.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .perchFont(.body)
        .frame(minWidth: Theme.Size.stripMaxWidth.value, minHeight: Theme.Size.peekWidth.value)
    }

    @ViewBuilder private var content: some View {
        switch selection.tab {
        case .yourWeek: YourWeekView()
        case .history: HistoryView()
        case .projects: ProjectsView()
        }
    }
}

/// A scoped native host makes the selected SwiftUI key view discoverable without
/// guessing a private class name or matching unrelated controls in the window.
private struct DashboardTabs: NSViewRepresentable {
    let selection: DashboardSelection
    @Environment(\.self) private var environment

    func makeNSView(context: Context) -> DashboardTabsHost {
        let view = DashboardTabsHost(selection: selection, environment: environment)
        view.setAccessibilityIdentifier("dashboard-tabs-host")
        return view
    }

    func updateNSView(_ view: DashboardTabsHost, context: Context) {
        view.updateEnvironment(environment)
        view.refreshKeyLoop()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DashboardTabsHost, context: Context) -> CGSize? {
        nsView.fittingSize
    }
}

@MainActor
private final class DashboardTabEnvironment: ObservableObject {
    @Published var values: EnvironmentValues
    init(_ values: EnvironmentValues) { self.values = values }
}

/// Retain the segmented control's focus state across content changes. Updating
/// the model or environment must not replace the nested hosting root.
private struct DashboardTabContent: View {
    @ObservedObject var selection: DashboardSelection
    @ObservedObject var environment: DashboardTabEnvironment
    let navigate: (Bool) -> Bool

    var body: some View {
        PerchSegmented(
            title: "Section", items: DashboardView.Tab.allCases.map { ($0, $0.rawValue) },
            selection: $selection.tab, surface: .sheet
        )
        .accessibilityIdentifier("dashboard-tabs")
        .environment(\.self, environment.values)
        // The component first cancels its deferred focus restoration, then this
        // outer handler crosses the nested hosting boundary through native links.
        .onKeyPress(.tab, phases: .down) { press in navigate(press.modifiers.contains(.shift)) ? .handled : .ignored }
        .onKeyPress(KeyEquivalent("\u{19}")) { navigate(true) ? .handled : .ignored }
    }
}

final class DashboardTabsHost: NSHostingView<AnyView> {
    private(set) weak var selectionState: DashboardSelection?
    private var tabEnvironment: DashboardTabEnvironment?
    private var keyMonitor: Any?
    fileprivate var installingKeyLoop = false
    private var refreshing = false

    convenience init(selection: DashboardSelection, environment: EnvironmentValues) {
        self.init(rootView: AnyView(EmptyView()))
        selectionState = selection
        selection.tabHost = self
        let values = DashboardTabEnvironment(environment)
        tabEnvironment = values
        rootView = AnyView(
            DashboardTabContent(selection: selection, environment: values) { [weak self] backward in
                self?.moveFocus(backward: backward) ?? false
            })
    }

    func updateEnvironment(_ environment: EnvironmentValues) {
        tabEnvironment?.values = environment
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard window != nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleSelectionKey(event) ?? false }
            return handled ? nil : event
        }
        refreshKeyLoop()
    }

    override func layout() {
        super.layout()
        if let window { DashboardKeyLoop.install(in: window) }
    }

    /// All inputs, including a menu selection, publish through the same model.
    /// Preserve focus only when it is already inside this strip, never in a page.
    func selectionDidChange() {
        let keepFocus = ownsFirstResponder
        refreshKeyLoop()
        if keepFocus, let window, let tabs = DashboardKeyLoop.tabKeyView(in: window) {
            window.makeFirstResponder(tabs)
        }
    }

    func refreshKeyLoop() {
        guard !refreshing, let window else { return }
        refreshing = true
        window.contentView?.layoutSubtreeIfNeeded()
        DashboardKeyLoop.install(in: window)
        refreshing = false
        // SwiftUI can mount the conditional page after the model's didSet. The
        // immediate install is required; this follow-up only links new controls.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            DashboardKeyLoop.install(in: window)
        }
    }

    private var ownsFirstResponder: Bool {
        guard let window, window.isKeyWindow, let view = window.firstResponder as? NSView else { return false }
        return view === self || view.isDescendant(of: self)
    }

    /// Scope native selection to this strip. In particular, Space must not call
    /// an outgoing SwiftUI Button's action after an arrow changes the selection.
    func handleSelectionKey(_ event: NSEvent) -> Bool {
        guard (event.type == .keyDown || event.type == .keyUp), ownsFirstResponder,
            event.window === window,
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            tabEnvironment?.values.isEnabled != false,
            let selection = selectionState,
            let index = DashboardView.Tab.allCases.firstIndex(of: selection.tab)
        else { return false }
        let tabs = DashboardView.Tab.allCases
        let step = tabEnvironment?.values.layoutDirection == .rightToLeft ? -1 : 1
        let destination: DashboardView.Tab
        switch event.keyCode {
        case 123: destination = tabs[min(max(index - step, 0), tabs.count - 1)]
        case 124: destination = tabs[min(max(index + step, 0), tabs.count - 1)]
        case 115: destination = tabs[0]
        case 119: destination = tabs[tabs.count - 1]
        case 49: destination = selection.tab
        default: return false
        }
        if event.type == .keyDown, !event.isARepeat {
            selection.tab = destination
        }
        return true
    }

    func moveFocus(backward: Bool) -> Bool {
        guard ownsFirstResponder, let window else { return false }
        DashboardKeyLoop.install(in: window)
        guard let tabs = DashboardKeyLoop.tabKeyView(in: window),
            let target = backward ? tabs.previousValidKeyView : tabs.nextValidKeyView
        else { return false }
        return window.makeFirstResponder(target)
    }
}

/// History's native field editor and the shared SwiftUI tabs use one explicit loop.
@MainActor
enum DashboardKeyLoop {
    static let searchIdentifier = "dashboard-history-search"
    private static var projectActionMonitor: Any?

    /// Install once for the app lifetime, without retaining a window or a page.
    /// The cell's native activation may bypass the button's key handlers, so
    /// reject unsafe Space events before AppKit starts dispatching them.
    private static func installProjectActionMonitor() {
        guard projectActionMonitor == nil else { return }
        projectActionMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { handleProjectActionKey(event) }
            return handled ? nil : event
        }
    }

    private static func handleProjectActionKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 49,
            !event.modifierFlags.intersection([.command, .control, .option]).isEmpty || event.isARepeat,
            let window = event.window, window.isKeyWindow,
            let root = window.contentView,
            let host = descendants(root).compactMap({ $0 as? DashboardTabsHost }).first,
            host.selectionState?.tab == .projects,
            let focused = window.firstResponder as? NSView
        else { return false }
        var candidate: NSView? = focused
        while let view = candidate {
            if let action = view as? DashboardProjectActionView {
                guard action.window === window, action.isDescendant(of: root), action.acceptsFirstResponder else {
                    return false
                }
                #if DASHBOARD_KEYBOARD_PROBE
                    let identifier = action.accessibilityIdentifier() ?? "nil"
                    let message =
                        "TRACE: DashboardKeyLoop swallowed type=\(event.type.rawValue) keyCode=\(event.keyCode) "
                        + "modifiers=\(event.modifierFlags.rawValue) isARepeat=\(event.isARepeat) "
                        + "responderIdentifier=\(identifier)\n"
                    FileHandle.standardError.write(Data(message.utf8))
                #endif
                return true
            }
            candidate = view.superview
        }
        return false
    }

    static func tabKeyView(in window: NSWindow) -> NSView? {
        guard let root = window.contentView,
            let host = descendants(root).compactMap({ $0 as? DashboardTabsHost }).first
        else { return nil }
        return descendants(host).first { $0 !== host && $0.canBecomeKeyView }
    }

    static func install(in window: NSWindow) {
        guard window.isVisible, let root = window.contentView,
            let host = descendants(root).compactMap({ $0 as? DashboardTabsHost }).first,
            !host.installingKeyLoop
        else { return }
        installProjectActionMonitor()
        host.installingKeyLoop = true
        defer { host.installingKeyLoop = false }
        window.autorecalculatesKeyViewLoop = false
        // Native page controls have a complete deterministic loop. Recalculating
        // their nested hosting views on every layout re-enters SwiftUI focus
        // updates, including while a closing window is tearing down.
        if installNativePaneLoop(in: window, root: root, host: host) { return }
        window.recalculateKeyViewLoop()
        guard let tabs = tabKeyView(in: window) else { return }
        let following = nextPageKeyView(after: tabs, outside: host)
        // The strip is the first stop on every page, even when History's search
        // does not exist. Capture the natural successor before adding this edge.
        window.initialFirstResponder = tabs
        root.nextKeyView = tabs
        tabs.nextKeyView = following ?? tabs
        if host.selectionState?.tab == .projects {
            // The page's destructive actions have concrete native targets. Do not
            // enter a SwiftUI focus proxy that can discard Tab and Space instead.
            let actions = descendants(root).compactMap({ $0 as? DashboardProjectActionView })
                .filter { action in action.canBecomeKeyView }
            if let first = actions.first {
                tabs.nextKeyView = first
                for (index, action) in actions.enumerated() {
                    action.nextKeyView = index + 1 < actions.count ? actions[index + 1] : tabs
                }
            }
        }
        guard host.selectionState?.tab == .history,
            let search = descendants(root).compactMap({ $0 as? NSTextField }).first(where: {
                $0.identifier?.rawValue == searchIdentifier && !$0.isHiddenOrHasHiddenAncestor
            })
        else { return }
        let afterSearch = nextPageKeyView(after: search, outside: host)
        tabs.nextKeyView = search
        search.nextKeyView = afterSearch === search ? tabs : (afterSearch ?? tabs)
    }

    /// Link the named entry controls first, then every remaining native document
    /// control. Only change edges when necessary; never rebuild a hosted focus
    /// tree as a side effect of painting its focus ring.
    private static func installNativePaneLoop(in window: NSWindow, root: NSView, host: DashboardTabsHost) -> Bool {
        guard host.selectionState?.tab != .yourWeek, let tabs = tabKeyView(in: window) else { return false }
        let page = descendants(root).filter {
            $0 is NSControl && $0.canBecomeKeyView && !$0.isDescendant(of: host)
        }
        guard page.contains(where: { $0 is DashboardPaneActionView }) else { return false }
        var entry: [NSView] = []
        if host.selectionState?.tab == .history {
            if let search = page.first(where: { $0.identifier?.rawValue == searchIdentifier }) { entry.append(search) }
            for name in ["everything", "carried", "time", "agent"] {
                if let filter = page.first(where: { $0.identifier?.rawValue == "history-filter-\(name)" }) {
                    entry.append(filter)
                }
            }
        } else {
            entry = page.filter { $0.identifier?.rawValue.hasPrefix("project-options-") == true }
        }
        let controls = [tabs] + entry + page.filter { candidate in !entry.contains { $0 === candidate } }
        if window.initialFirstResponder !== tabs { window.initialFirstResponder = tabs }
        if root.nextKeyView !== tabs { root.nextKeyView = tabs }
        for (index, control) in controls.enumerated() {
            let next = controls[(index + 1) % controls.count]
            if control.nextKeyView !== next { control.nextKeyView = next }
        }
        return true
    }

    /// Skip only hosting infrastructure and strip-internal proxies, preserving
    /// the window's recalculated order for the current page's actual controls.
    private static func nextPageKeyView(after view: NSView, outside host: DashboardTabsHost) -> NSView? {
        var next = view.nextValidKeyView
        var visited = Set<ObjectIdentifier>()
        while let candidate = next, visited.insert(ObjectIdentifier(candidate)).inserted {
            if candidate !== view, candidate !== host,
                !candidate.isDescendant(of: host), !host.isDescendant(of: candidate)
            {
                return candidate
            }
            next = candidate.nextValidKeyView
        }
        return nil
    }

    private static func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }
}

/// Token-based paint has no SwiftUI Tab stop. One native button owns focus,
/// accessibility and activation, including when the enclosing page is rebuilt.
struct DashboardProjectDeleteButton: View {
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var focused = false
    @State private var pressed = false

    var body: some View {
        Text(AppL10n.text("Delete project"))
            .font(Theme.label)
            .padding(.horizontal, Theme.Size.segmentRadius.value)
            .frame(minWidth: Theme.minimumTarget, minHeight: Theme.primaryHeight)
            .foregroundStyle(Theme.text)
            .background(Capsule().fill(Theme.fill))
            .overlay(Capsule().strokeBorder(Theme.inputStroke, lineWidth: Theme.Size.checkboxStroke.value / 2))
            .overlay(ControlFocusRing(shape: Capsule(), focused: focused && enabled))
            .perchControlFeedback(pressed: pressed)
            .accessibilityHidden(true)
            .overlay {
                DashboardProjectActionTarget(
                    enabled: enabled, action: action,
                    focusChanged: { focused = $0 }, pressChanged: { pressed = $0 })
            }
    }
}

private struct DashboardProjectActionTarget: NSViewRepresentable {
    let enabled: Bool
    let action: () -> Void
    let focusChanged: (Bool) -> Void
    let pressChanged: (Bool) -> Void

    func makeNSView(context: Context) -> DashboardProjectActionView { DashboardProjectActionView() }

    func updateNSView(_ view: DashboardProjectActionView, context: Context) {
        view.onAction = action
        view.focusChanged = focusChanged
        view.pressChanged = pressChanged
        view.isEnabled = enabled
        if !enabled, view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
    }
}

/// A transparent native action over the shared paint, not a proxy for a second button.
final class DashboardProjectActionView: NSButton {
    var onAction: () -> Void = {}
    var focusChanged: (Bool) -> Void = { _ in }
    var pressChanged: (Bool) -> Void = { _ in }
    private var activationEvent: NSEvent?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title = AppL10n.text("Delete project")
        isTransparent = true
        focusRingType = .none
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(activateProjectAction(_:))
        setAccessibilityIdentifier("dashboard-project-delete")
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                DashboardKeyLoop.install(in: window)
            }
        }
        updateFocusPaint()
    }

    override func becomeFirstResponder() -> Bool {
        guard acceptsFirstResponder, super.becomeFirstResponder() else { return false }
        updateFocusPaint()
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        updateFocusPaint()
        return true
    }

    private func updateFocusPaint() {
        // Native focus is synchronous; paint publication waits until SwiftUI has
        // finished the layout which may have mounted this representable.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusChanged(self.window?.isKeyWindow == true && self.window?.firstResponder === self)
        }
    }

    override func keyDown(with event: NSEvent) {
        #if DASHBOARD_KEYBOARD_PROBE
            if event.keyCode == 49 { traceProjectAction("keyDown", event: event) }
        #endif
        if event.keyCode == 49 {
            // NSButton may activate even modified Space. Keep one deliberate
            // activation path here and never forward Space to the superclass.
            guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                !event.isARepeat, event.window === window,
                window?.isKeyWindow == true, window?.firstResponder === self, acceptsFirstResponder
            else { return }
            withActivationEvent(event) { performClick(nil) }
            return
        }
        if event.keyCode == 48,
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        {
            if event.modifierFlags.contains(.shift) {
                window?.selectPreviousKeyView(self)
            } else {
                window?.selectNextKeyView(self)
            }
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        #if DASHBOARD_KEYBOARD_PROBE
            if event.keyCode == 49 { traceProjectAction("keyUp", event: event) }
        #endif
        if event.keyCode == 49 { return }
        super.keyUp(with: event)
    }

    override func performClick(_ sender: Any?) {
        if let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 49,
            !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty || event.isARepeat
        {
            return
        }
        super.performClick(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit can press a focused button here without calling keyDown.
        // Preserve the supplied event through its synchronous target/action.
        withActivationEvent(event) { super.performKeyEquivalent(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        guard acceptsFirstResponder else { return }
        pressChanged(true)
        defer { pressChanged(false) }
        withActivationEvent(event) { super.mouseDown(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard window != nil, acceptsFirstResponder else { return false }
        withActivationEvent(nil) { performClick(nil) }
        return true
    }

    private func withActivationEvent<T>(_ event: NSEvent?, _ body: () -> T) -> T {
        let previous = activationEvent
        activationEvent = event
        defer { activationEvent = previous }
        return body()
    }

    @objc private func activateProjectAction(_ sender: Any?) {
        #if DASHBOARD_KEYBOARD_PROBE
            traceProjectAction("activateProjectAction")
        #endif
        guard window != nil, acceptsFirstResponder else { return }
        // Do not rely on NSApp.currentEvent: direct sendEvent calls need not
        // update it, and accessibility/programmatic presses are not key events.
        if let event = activationEvent, event.type == .keyDown || event.type == .keyUp {
            guard event.type == .keyDown, event.keyCode == 49,
                event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                !event.isARepeat, event.window === window,
                window?.isKeyWindow == true, window?.firstResponder === self
            else { return }
        }
        onAction()
    }

    #if DASHBOARD_KEYBOARD_PROBE
        private func traceProjectAction(_ phase: String, event: NSEvent? = nil) {
            // Direct sendEvent can leave currentEvent nil or pointing at another
            // event. Record both without changing the native dispatch under test.
            func eventSummary(_ event: NSEvent?) -> String {
                guard let event else { return "nil" }
                let keyCode: String
                switch event.type {
                case .keyDown, .keyUp, .flagsChanged: keyCode = String(event.keyCode)
                default: keyCode = "not-key"
                }
                return "type=\(event.type.rawValue),keyCode=\(keyCode),modifiers=\(event.modifierFlags.rawValue)"
            }
            let responder = window?.firstResponder
            let responderType = responder.map { String(describing: type(of: $0)) } ?? "nil"
            let identifier = (responder as? NSView)?.accessibilityIdentifier() ?? "nil"
            let message =
                "TRACE: DashboardProjectAction \(phase) instance=\(ObjectIdentifier(self)) "
                + "event=\(eventSummary(event)) currentEvent=\(eventSummary(NSApp.currentEvent)) "
                + "responder=\(responderType) responderIdentifier=\(identifier) "
                + "stack=\(Thread.callStackSymbols.joined(separator: " | "))\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    #endif
}
