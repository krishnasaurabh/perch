import PerchUI
import SwiftUI

/// The shared dashboard supplies the window header and sheet.
struct HistoryView: View {
    static func subtitle(store: PlannerStore) -> String {
        AppL10n.text("Everything you finished, day by day.")
    }

    var body: some View { HistoryList() }

    #if DEBUG || PERCH_TESTING
        static func preview(_ filter: HistoryModel.Filter, app: AppDelegate) {
            HistoryPreviewState.shared.filter = filter
            DashboardWindow.show(store: app.store, tab: .history)
        }
    #endif
}
