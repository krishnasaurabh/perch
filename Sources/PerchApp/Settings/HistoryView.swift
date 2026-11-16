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
