import SwiftUI

/// Connection state is owned by the window, not discarded when changing panes.
struct SettingsAgentsPane: View {
    @Binding var statuses: [AgentConnector.App: AgentConnector.Status]
    @ObservedObject var feedback: SettingsFailureFeedback

    var body: some View {
        Card(.paper) {
            VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
                AgentsSettings(statuses: $statuses, feedback: feedback)
            }
        }
    }
}
