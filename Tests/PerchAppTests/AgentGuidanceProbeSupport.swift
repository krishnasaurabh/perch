#if AGENT_GUIDANCE_SUPPORT
    import AppKit
    import EventKit
    import PlannerCore
    import SwiftUI

    /// Copied only into the disposable probe library. Production keeps its own constructor.
    @MainActor
    final class AgentGuidanceFixture {
        private static var fixtures: [ObjectIdentifier: AgentGuidanceFixture] = [:]
        let root: URL
        let app: AgentConnector.App
        let store: PlannerStore
        let delegate: AppDelegate
        var window: NSWindow { hostedWindow! }
        let originalPlanner: Data
        let guidance = "Restart the sample app."
        private var statusBinding: Binding<[AgentConnector.App: AgentConnector.Status]>?
        var statuses: [AgentConnector.App: AgentConnector.Status] { statusBinding?.wrappedValue ?? [:] }
        var shouldFail = true
        var attempts = 0
        var config: URL { root.appendingPathComponent("connection.json") }
        var disconnectID: String { "settings.agents.\(app.rawValue).disconnect" }

        init(app: AgentConnector.App) throws {
            try guidanceNil(Bundle.main.bundleIdentifier)
            let calendarStatus = EKEventStore.authorizationStatus(for: .event)
            try guidanceRequire(
                calendarStatus == .notDetermined || calendarStatus == .denied || calendarStatus == .restricted,
                "The fixture must not read an authorized calendar")
            self.app = app
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let file = PlannerFile(
                url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
            var planner = Planner()
            planner.preferences.catchCopies = false
            planner.preferences.catchScreenshots = false
            planner.preferences.remindersSync = false
            try file.save(planner)
            store = PlannerStore(file: file, watching: false)
            // Complete ordinary launch bookkeeping before the byte-identity baseline.
            // Later notification reconciliation must not clear a connection failure.
            store.beginApplication()
            originalPlanner = try Data(contentsOf: file.url)
            try guidanceNil(AppDelegate.snapshotDate)
            delegate = AppDelegate()
            delegate.store = store
            delegate.services = Services(store: store)
            // Initialize all stored fields before publishing self to the constructor seam.
            Self.fixtures[ObjectIdentifier(store)] = self
            // Keep the first window alive while the registry opens a genuinely independent second window.
            WindowHost.windows.removeValue(forKey: "settings")
            let target = try AppDelegate.previewTarget("settings/agents-connected")
            try guidanceEqual(AppDelegate.previewOption("--open"), "settings/agents-connected")
            target.open(delegate)
            let rendered = try guidanceUnwrap(target.surface(delegate)?.0)
            hostedWindow = rendered
        }

        private var hostedWindow: NSWindow?

        static func agents(
            statuses: Binding<[AgentConnector.App: AgentConnector.Status]>,
            feedback: SettingsFailureFeedback, store: PlannerStore
        ) -> AgentsSettings {
            guard let fixture = fixtures[ObjectIdentifier(store)] else {
                preconditionFailure("Missing isolated connector fixture")
            }
            fixture.statusBinding = statuses
            return AgentsSettings(
                statuses: statuses, feedback: feedback, readStatus: fixture.readStatus,
                disconnect: fixture.disconnect, connect: fixture.connect)
        }

        func readStatus(_ candidate: AgentConnector.App) -> AgentConnector.Status {
            guard candidate == app else { return .notInstalled }
            return AgentConnector.jsonHasServer(config, path: ["mcpServers"]) ? .connected : .notConnected
        }

        func connect(_ candidate: AgentConnector.App) throws -> String {
            try guidanceEqual(candidate, app)
            attempts += 1
            if shouldFail { throw PlannerError("Sample connection failure.") }
            try AgentConnector.addServer(to: config)
            return guidance
        }

        func disconnect(_ candidate: AgentConnector.App) throws {
            try guidanceEqual(candidate, app)
            try AgentConnector.removeServer(from: config)
        }

        func close() {
            window.contentView = nil
            window.close()
            Self.fixtures.removeValue(forKey: ObjectIdentifier(store))
            try? FileManager.default.removeItem(at: root)
        }
    }
#endif
