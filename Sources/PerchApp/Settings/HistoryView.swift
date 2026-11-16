import SwiftUI

/// Keeps the existing content available while this tab is built independently.
struct HistoryView: View {
    static func subtitle(store: PlannerStore) -> String {
        AppL10n.text("Everything you finished, day by day.")
    }

    var body: some View { HistoryList() }
}
