import PlannerCore
import SwiftUI

/// Connection state is owned by the window, not discarded when changing panes.
struct SettingsAgentsPane: View {
    @EnvironmentObject var store: PlannerStore
    @Binding var statuses: [AgentConnector.App: AgentConnector.Status]
    @ObservedObject var feedback: SettingsFailureFeedback

    var body: some View {
        AgentsSettings(statuses: $statuses, feedback: feedback)
        SettingsSection("What agents may do") {
            preferenceRow(.agentsCanEditTasks)
            preferenceRow(.agentsCanControlTime)
            preferenceRow(.agentsCanReadParkingLot)
        }
        SettingsSection("Their changes") {
            preferenceRow(.showAgentAttribution)
            preferenceRow(.confirmAgentDeletes)
            Text("Anything an agent does shows up in the notch and can be undone with ⌘Z.")
                .perchFont(.detail)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, SettingsMetrics.sectionGap)
        }
    }

    private func preferenceRow(_ preference: AgentSettingsPreference) -> some View {
        SettingsRow(preference.title) {
            PerchSwitch(title: preference.title, isOn: preference.binding(in: store))
                .accessibilityIdentifier("settings.agents.\(preference.rawValue)")
        }
    }

    #if DEBUG || PERCH_TESTING
        static func previewConnected(app: AppDelegate) {
            WindowHost.show("settings", title: "Perch Settings", size: SettingsMetrics.windowSize) {
                SettingsView(navigation: SettingsNavigation(pane: .agents))
                    .environmentObject(app.store).environmentObject(app.services)
                    .environment(\.agentPreviewConnected, true)
            }
        }
    #endif
}

/// One definition ties each visible switch to its stored field and typed command.
enum AgentSettingsPreference: String, CaseIterable {
    case agentsCanEditTasks, agentsCanControlTime, agentsCanReadParkingLot
    case showAgentAttribution, confirmAgentDeletes

    var title: String {
        switch self {
        case .agentsCanEditTasks: AppL10n.text("Add and edit tasks")
        case .agentsCanControlTime: AppL10n.text("Start and stop time blocks")
        case .agentsCanReadParkingLot: AppL10n.text("Read the parking lot")
        case .showAgentAttribution: AppL10n.text("Show who added a task")
        case .confirmAgentDeletes: AppL10n.text("Ask me before an agent deletes")
        }
    }

    var keyPath: KeyPath<Preferences, Bool> {
        switch self {
        case .agentsCanEditTasks: \.agentsCanEditTasks
        case .agentsCanControlTime: \.agentsCanControlTime
        case .agentsCanReadParkingLot: \.agentsCanReadParkingLot
        case .showAgentAttribution: \.showAgentAttribution
        case .confirmAgentDeletes: \.confirmAgentDeletes
        }
    }

    func update(_ value: Bool) -> PreferenceUpdate {
        switch self {
        case .agentsCanEditTasks: .agentsCanEditTasks(value)
        case .agentsCanControlTime: .agentsCanControlTime(value)
        case .agentsCanReadParkingLot: .agentsCanReadParkingLot(value)
        case .showAgentAttribution: .showAgentAttribution(value)
        case .confirmAgentDeletes: .confirmAgentDeletes(value)
        }
    }

    @MainActor
    func binding(in store: PlannerStore) -> Binding<Bool> {
        Binding(
            get: { store.prefs[keyPath: keyPath] },
            set: { value in store.apply { try $0.updatePreference(update(value)) } })
    }
}
