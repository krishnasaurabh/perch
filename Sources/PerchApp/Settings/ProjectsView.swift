import SwiftUI

/// Project cards share the dashboard window and its Undo routing.
struct ProjectsView: View {
    static func subtitle(store: PlannerStore) -> String {
        AppL10n.text("Group the tasks that belong together.")
    }

    var body: some View { DashboardPane { ProjectsList() } }

    #if DEBUG || PERCH_TESTING
        static func preview(_ mode: ProjectsPreviewState.Mode, app: AppDelegate) {
            ProjectsPreviewState.shared.mode = mode
            DashboardWindow.show(store: app.store, tab: .projects)
        }
    #endif
}
