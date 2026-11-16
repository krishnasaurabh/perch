import SwiftUI

/// Keeps the existing content available while this tab is built independently.
struct YourWeekView: View {
    static func subtitle(store: PlannerStore) -> String {
        AppL10n.text("A look at what you did this week.")
    }

    var body: some View { InsightsDashboard() }
}
