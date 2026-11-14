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
                title: AppL10n.text(tab.windowTitle), action: #selector(DashboardMenuAction.perform(_:)),
                keyEquivalent: "")
            item.target = target
            item.representedObject = target
            menu.insertItem(item, at: insertion + offset)
        }
    }
}

@MainActor
final class DashboardSelection: ObservableObject {
    @Published var tab: DashboardView.Tab
    init(tab: DashboardView.Tab = .yourWeek) { self.tab = tab }
}

@MainActor
private final class DashboardMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func perform(_ sender: NSMenuItem) { action() }
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
                    DashboardTabs(selection: $selection.tab)
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
    @Binding var selection: DashboardView.Tab
    @Environment(\.self) private var environment

    private var content: AnyView {
        AnyView(
            PerchSegmented(
                title: "Section", items: DashboardView.Tab.allCases.map { ($0, $0.rawValue) },
                selection: $selection, surface: .sheet
            ).environment(\.self, environment))
    }

    func makeNSView(context: Context) -> DashboardTabsHost { DashboardTabsHost(rootView: content) }

    func updateNSView(_ view: DashboardTabsHost, context: Context) {
        view.rootView = content
        view.refreshKeyLoop()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DashboardTabsHost, context: Context) -> CGSize? {
        nsView.fittingSize
    }
}

final class DashboardTabsHost: NSHostingView<AnyView> {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshKeyLoop()
    }

    func refreshKeyLoop() {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            DashboardKeyLoop.install(in: window)
        }
    }
}

/// History's native field editor and the shared SwiftUI tabs use one explicit loop.
@MainActor
enum DashboardKeyLoop {
    static let searchIdentifier = "dashboard-history-search"

    static func tabKeyView(in window: NSWindow) -> NSView? {
        guard let root = window.contentView,
            let host = descendants(root).compactMap({ $0 as? DashboardTabsHost }).first
        else { return nil }
        return descendants(host).first { $0 !== host && $0.canBecomeKeyView }
    }

    static func install(in window: NSWindow) {
        guard let root = window.contentView else { return }
        window.recalculateKeyViewLoop()
        guard let tabs = tabKeyView(in: window),
            let search = descendants(root).compactMap({ $0 as? NSTextField }).first(where: {
                $0.identifier?.rawValue == searchIdentifier
            })
        else { return }
        let following = search.nextValidKeyView
        tabs.nextKeyView = search
        search.nextKeyView = following === search ? tabs : (following ?? tabs)
    }

    private static func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }
}
