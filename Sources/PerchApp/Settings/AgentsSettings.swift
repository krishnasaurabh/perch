import AppKit
import PlannerCore
import SwiftUI

struct AgentsSettings: View {
    @EnvironmentObject var store: PlannerStore
    @Environment(\.agentPreviewConnected) private var previewConnected
    @Binding var statuses: [AgentConnector.App: AgentConnector.Status]
    @ObservedObject var feedback: SettingsFailureFeedback
    var readStatus: @MainActor (AgentConnector.App) -> AgentConnector.Status
    var disconnect: @MainActor (AgentConnector.App) throws -> Void
    var connect: @MainActor (AgentConnector.App) throws -> String
    @Binding private var message: String?

    init(
        statuses: Binding<[AgentConnector.App: AgentConnector.Status]>, feedback: SettingsFailureFeedback,
        readStatus: @escaping @MainActor (AgentConnector.App) -> AgentConnector.Status = AgentsSettings
            .connectionStatus,
        disconnect: @escaping @MainActor (AgentConnector.App) throws -> Void = AgentConnector.disconnect,
        connect: @escaping @MainActor (AgentConnector.App) throws -> String = AgentConnector.connect
    ) {
        _statuses = statuses
        self.feedback = feedback
        self.readStatus = readStatus
        self.disconnect = disconnect
        self.connect = connect
        // Both the visible pane and a retained Retry write to the same window-owned message.
        _message = Binding(
            get: { [weak feedback] in feedback?.agentConnectionMessage },
            set: { [weak feedback] in feedback?.agentConnectionMessage = $0 })
    }

    var body: some View {
        SettingsSection("Connected apps") {
            if !AppInfo.isInApplications && !Self.isPreview {
                VStack(alignment: .leading, spacing: SettingsMetrics.titleGap) {
                    Text("Connect AI agents").perchFont(.stripTitle)
                    Text("Agent setup requires Perch to be installed in Applications.")
                        .perchFont(.detail).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Or use Terminal").perchFont(.detail)
                    Text(AgentConnector.terminalCommand).perchFont(.detail).monospaced()
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    PerchButton("Copy", kind: .soft, size: .small) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AgentConnector.terminalCommand, forType: .string)
                        message = AppL10n.text("Copied")
                    }
                }
                .padding(.vertical, SettingsMetrics.titleGap)
            }
            for app in AgentConnector.App.allCases {
                SettingsRow(Self.name(app)) {
                    HStack(spacing: SettingsMetrics.rowGap) {
                        switch statuses[app] ?? .notConnected {
                        case .connected:
                            Text("Connected").perchFont(.detail).foregroundStyle(Theme.doneText)
                            PerchButton("Disconnect", kind: .quiet, size: .small) { disconnectAgent(app) }
                                .accessibilityIdentifier("settings.agents.\(app.rawValue).disconnect")
                        case .notConnected:
                            PerchButton("Connect", kind: .soft, size: .small) { connectAgent(app) }
                                .accessibilityValue("Not connected")
                                .accessibilityIdentifier("settings.agents.\(app.rawValue).connect")
                        case .notInstalled:
                            Text("Not installed").perchFont(.detail).foregroundStyle(Theme.ink2)
                            if app == .claudeApp {
                                PerchButton("Get it", kind: .quiet, size: .small) {
                                    if let url = URL(string: "https://claude.ai/download") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                            }
                            PerchButton("Connect", kind: .soft, size: .small) {}
                                .disabled(true)
                                .help("Install the app before connecting it to Perch.")
                        }
                    }
                }
            }
            if let message {
                Text(message).perchFont(.detail).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, SettingsMetrics.titleGap)
            }
        }
        .onAppear(perform: refresh)
    }

    static func name(_ app: AgentConnector.App) -> String {
        switch app {
        case .claudeCode: AppL10n.text("Claude Code")
        case .claudeApp: AppL10n.text("Claude Desktop")
        case .cursor: AppL10n.text("Cursor")
        }
    }

    static var isPreview: Bool {
        #if DEBUG || PERCH_TESTING
            AppDelegate.snapshotDate != nil
        #else
            false
        #endif
    }

    static func connectionStatus(_ app: AgentConnector.App) -> AgentConnector.Status {
        isPreview ? .notConnected : AgentConnector.status(app)
    }

    func connectAgent(_ app: AgentConnector.App) {
        guard !Self.isPreview else { return }
        message = Self.connectAgent(
            app, store: store, statuses: $statuses, feedback: feedback,
            readStatus: readStatus, connect: connect, message: $message)
    }

    func disconnectAgent(_ app: AgentConnector.App) {
        guard !Self.isPreview else { return }
        message = nil
        Self.disconnectAgent(
            app, store: store, statuses: $statuses, feedback: feedback,
            readStatus: readStatus, disconnect: disconnect)
    }

    /// Refresh from configuration only after the connector confirms success.
    static func connectAgent(
        _ app: AgentConnector.App, store: PlannerStore,
        statuses: Binding<[AgentConnector.App: AgentConnector.Status]>, feedback: SettingsFailureFeedback,
        readStatus: @escaping @MainActor (AgentConnector.App) -> AgentConnector.Status,
        connect: @escaping @MainActor (AgentConnector.App) throws -> String,
        message: Binding<String?>? = nil
    ) -> String? {
        var initialMessage: String?
        feedback.perform(store: store, failure: { .planner($0.perchPresentationDetail) }) { [weak feedback] in
            guard let feedback else { return }
            let result = try connect(app)
            guard readStatus(app) == .connected else {
                throw PlannerError("Perch could not confirm the connection. Check the app and try again.")
            }
            statuses.wrappedValue[app] = .connected
            feedback.failedAgentDisconnects.remove(app)
            initialMessage = result
            // Retry retains this binding, so guidance reaches the view after later successes too.
            message?.wrappedValue = result
        }
        return initialMessage
    }

    static func disconnectAgent(
        _ app: AgentConnector.App, store: PlannerStore,
        statuses: Binding<[AgentConnector.App: AgentConnector.Status]>, feedback: SettingsFailureFeedback,
        readStatus: @escaping @MainActor (AgentConnector.App) -> AgentConnector.Status,
        disconnect: @escaping @MainActor (AgentConnector.App) throws -> Void
    ) {
        feedback.perform(store: store, failure: { .planner($0.perchPresentationDetail) }) { [weak feedback] in
            guard let feedback else { return }
            do {
                try disconnect(app)
                let status = readStatus(app)
                guard status != .connected else {
                    throw PlannerError("Perch is still connected. Check the app and try again.")
                }
                statuses.wrappedValue[app] = status
                feedback.failedAgentDisconnects.remove(app)
            } catch {
                // Preserve last-known state across pane re-entry if configuration is unreadable.
                feedback.failedAgentDisconnects.insert(app)
                throw error
            }
        }
    }

    func refresh() {
        for app in AgentConnector.App.allCases where !feedback.failedAgentDisconnects.contains(app) {
            statuses[app] = Self.isPreview && previewConnected && app == .claudeCode ? .connected : readStatus(app)
        }
    }
}

/// The connected sample never reads or modifies installed agents' configuration.
private struct AgentPreviewConnectedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var agentPreviewConnected: Bool {
        get { self[AgentPreviewConnectedKey.self] }
        set { self[AgentPreviewConnectedKey.self] = newValue }
    }
}
