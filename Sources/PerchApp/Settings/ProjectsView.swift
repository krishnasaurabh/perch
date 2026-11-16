import SwiftUI

/// Keeps the existing content available while this tab is built independently.
struct ProjectsView: View {
    static func subtitle(store: PlannerStore) -> String {
        AppL10n.text("Group the tasks that belong together.")
    }

    var body: some View { ProjectsList() }
}
