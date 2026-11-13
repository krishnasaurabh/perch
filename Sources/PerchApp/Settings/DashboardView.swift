import AppKit
import SwiftUI

enum DashboardWindow {
    @MainActor static func show(store: PlannerStore, tab: DashboardView.Tab = .insights) {
        WindowHost.show(
            "dashboard", title: "Perch", size: CGSize(width: 900, height: 640),
            onUndo: { redo in redo ? store.redo() : store.undo() }
        ) {
            DashboardView(tab: tab).environmentObject(store).environment(\.accessibilityEnabled, true)
        }
    }

    @MainActor static func show(store: PlannerStore, model: NotchModel, services: Services) {
        WindowHost.show(
            "dashboard", title: "Perch", size: CGSize(width: 900, height: 640),
            onUndo: { redo in redo ? store.redo() : store.undo() }
        ) {
            DashboardView().environmentObject(store).environmentObject(model).environmentObject(services)
        }
    }
}

// MARK: - Dashboard: Today, Upcoming, History, Insights

struct DashboardView: View {
    @EnvironmentObject var store: PlannerStore
    @State private var tab: Tab
    enum Tab: String, CaseIterable {
        case upcoming = "Upcoming", history = "History", insights = "Insights", projects = "Projects"
    }

    init(tab: Tab = .insights) { _tab = State(initialValue: tab) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Dashboard section", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text(AppL10n.text($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 420).padding(.top, 34).padding(.bottom, 12)
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .upcoming: UpcomingList()
                    case .history: HistoryList()
                    case .insights: InsightsDashboard()
                    case .projects: ProjectsList()
                    }
                }.padding(20)
            }
        }
        .font(Theme.body)
        .foregroundStyle(Theme.text)
        .environment(\.controlSurface, Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 720, minHeight: 520)
        .background(DashboardKeyLoopBridge(selection: tab))
    }
}

/// Rebuild the native loop when a dashboard page changes. History's editor is
/// hosted separately by AppKit, so leaving these links implicit traps back-tab.
@MainActor
enum DashboardKeyLoop {
    static let searchIdentifier = "dashboard-history-search"

    static func install(in window: NSWindow) {
        guard let root = window.contentView else { return }
        window.recalculateKeyViewLoop()
        let views = descendants(root)
        guard
            let tabs = views.compactMap({ $0 as? NSSegmentedControl }).first(where: {
                $0.segmentCount == DashboardView.Tab.allCases.count
            }),
            let search = views.compactMap({ $0 as? NSTextField }).first(where: {
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

private struct DashboardKeyLoopBridge: NSViewRepresentable {
    let selection: DashboardView.Tab

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.refresh() }

    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refresh()
        }

        func refresh() {
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window else { return }
                DashboardKeyLoop.install(in: window)
            }
        }
    }
}
