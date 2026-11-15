import AppKit
import SwiftUI
import XCTest
@testable import PerchApp
@testable import PlannerCore

final class SettingsAgentsPaneTests: XCTestCase {
    @MainActor
    func testTaskEditingSwitchUsesItsStoredPreference() async throws {
        try exercise(.agentsCanEditTasks, key: \.agentsCanEditTasks, defaultValue: true)
    }

    @MainActor
    func testTimeControlSwitchUsesItsStoredPreference() async throws {
        try exercise(.agentsCanControlTime, key: \.agentsCanControlTime, defaultValue: false)
    }

    @MainActor
    func testParkingLotSwitchUsesItsStoredPreference() async throws {
        try exercise(.agentsCanReadParkingLot, key: \.agentsCanReadParkingLot, defaultValue: false)
    }

    @MainActor
    func testAttributionSwitchUsesItsStoredPreference() async throws {
        try exercise(.showAgentAttribution, key: \.showAgentAttribution, defaultValue: true)
    }

    @MainActor
    func testDeleteConfirmationSwitchUsesItsStoredPreference() async throws {
        try exercise(.confirmAgentDeletes, key: \.confirmAgentDeletes, defaultValue: true)
    }

    @MainActor
    private func exercise(
        _ control: AgentSettingsPreference, key: KeyPath<Preferences, Bool>, defaultValue: Bool
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = MemoryPlannerPreferences()
        let file = PlannerFile(url: root.appendingPathComponent("planner.json"), preferences: adapter)
        let store = PlannerStore(file: file, watching: false)
        let binding = control.binding(in: store)
        XCTAssertEqual(binding.wrappedValue, defaultValue)
        for value in [!defaultValue, defaultValue] {
            binding.wrappedValue = value
            XCTAssertNil(store.lastError)
            XCTAssertEqual(binding.wrappedValue, value)
            XCTAssertEqual(try file.load().preferences[keyPath: key], value)
            let encoded = try JSONEncoder().encode(XCTUnwrap(adapter.load()))
            let restartedFile = PlannerFile(
                url: file.url,
                preferences: MemoryPlannerPreferences(try JSONDecoder().decode(DevicePreferences.self, from: encoded)))
            let restartedStore = PlannerStore(file: restartedFile, watching: false)
            XCTAssertEqual(control.binding(in: restartedStore).wrappedValue, value)
            for other in AgentSettingsPreference.allCases where other != control {
                XCTAssertEqual(
                    restartedStore.prefs[keyPath: other.keyPath], Preferences()[keyPath: other.keyPath], other.rawValue)
            }
        }
    }

    @MainActor
    func testClaudeCodeConnectAndDisconnectReloadConfiguration() async throws {
        try exerciseConnection(.claudeCode)
    }

    @MainActor
    func testDesktopConnectAndDisconnectReloadConfiguration() async throws {
        try exerciseConnection(.claudeApp)
    }

    @MainActor
    func testCursorConnectAndDisconnectReloadConfiguration() async throws {
        try exerciseConnection(.cursor)
    }

    @MainActor
    private func exerciseConnection(_ app: AgentConnector.App) throws {
        let fixture = try AgentConnectionFixture()
        defer { fixture.close() }
        let original = try Data(contentsOf: fixture.store.file.url)
        let result = AgentsSettings.connectAgent(
            app, store: fixture.store, statuses: fixture.binding, feedback: fixture.feedback,
            readStatus: fixture.readStatus, connect: fixture.connect)
        XCTAssertEqual(result, "Restart the sample app.")
        XCTAssertNil(fixture.store.lastError)
        XCTAssertEqual(fixture.statuses[app], .connected)
        XCTAssertTrue(AgentConnector.jsonHasServer(fixture.url(app), path: ["mcpServers"]))
        let persisted = try AgentConnector.readConfig(fixture.url(app))
        XCTAssertEqual(persisted["preserve"] as? String, "sample setting")
        for other in AgentConnector.App.allCases where other != app {
            XCTAssertEqual(fixture.statuses[other], .notConnected)
            XCTAssertFalse(AgentConnector.jsonHasServer(fixture.url(other), path: ["mcpServers"]))
        }
        AgentsSettings.disconnectAgent(
            app, store: fixture.store, statuses: fixture.binding, feedback: fixture.feedback,
            readStatus: fixture.readStatus, disconnect: fixture.disconnect)
        XCTAssertNil(fixture.store.lastError)
        XCTAssertEqual(fixture.statuses[app], .notConnected)
        XCTAssertFalse(AgentConnector.jsonHasServer(fixture.url(app), path: ["mcpServers"]))
        XCTAssertEqual(try AgentConnector.readConfig(fixture.url(app))["preserve"] as? String, "sample setting")
        XCTAssertEqual(try Data(contentsOf: fixture.store.file.url), original)
    }

    @MainActor
    func testFailedConnectRetainsStateAndRetriesOnlyThatApp() async throws {
        let fixture = try AgentConnectionFixture()
        defer { fixture.close() }
        var fail = true
        var attempts: [AgentConnector.App] = []
        let result = AgentsSettings.connectAgent(
            .cursor, store: fixture.store, statuses: fixture.binding, feedback: fixture.feedback,
            readStatus: fixture.readStatus,
            connect: { app in
                attempts.append(app)
                if fail { throw PlannerError("Sample connection failure.") }
                return try fixture.connect(app)
            })
        XCTAssertNil(result)
        XCTAssertEqual(fixture.statuses[.cursor], .notConnected)
        let error = try XCTUnwrap(fixture.store.lastError)
        XCTAssertTrue(fixture.feedback.canRetry(error))
        fail = false
        fixture.feedback.retry(error)
        XCTAssertEqual(attempts, [.cursor, .cursor])
        XCTAssertNil(fixture.store.lastError)
        XCTAssertEqual(fixture.readStatus(.cursor), .connected)
        XCTAssertEqual(fixture.statuses[.claudeCode], .notConnected)
    }

    @MainActor
    func testConnectorSuccessIsNotClaimedWithoutPersistedConnection() async throws {
        let fixture = try AgentConnectionFixture()
        defer { fixture.close() }
        XCTAssertNil(
            AgentsSettings.connectAgent(
                .claudeCode, store: fixture.store, statuses: fixture.binding, feedback: fixture.feedback,
                readStatus: fixture.readStatus, connect: { _ in "Not written." }))
        XCTAssertNotNil(fixture.store.lastError)
        XCTAssertEqual(fixture.statuses[.claudeCode], .notConnected)
        try fixture.connect(.claudeCode)
        fixture.statuses[.claudeCode] = .connected
        AgentsSettings.disconnectAgent(
            .claudeCode, store: fixture.store, statuses: fixture.binding, feedback: fixture.feedback,
            readStatus: fixture.readStatus, disconnect: { _ in })
        XCTAssertNotNil(fixture.store.lastError)
        XCTAssertEqual(fixture.statuses[.claudeCode], .connected)
        XCTAssertTrue(fixture.feedback.failedAgentDisconnects.contains(.claudeCode))
    }

    @MainActor
    func testFailedPreferenceWriteKeepsTheSwitchAtItsStoredValue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = PlannerFile(url: root.appendingPathComponent("planner.json"), preferences: RejectAgentPreferences())
        let store = PlannerStore(file: file, watching: false)
        for control in AgentSettingsPreference.allCases {
            let binding = control.binding(in: store)
            let original = binding.wrappedValue
            binding.wrappedValue = !original
            XCTAssertNotNil(store.lastError)
            XCTAssertEqual(binding.wrappedValue, original)
            XCTAssertEqual(try file.load().preferences[keyPath: control.keyPath], original)
        }
    }
}

private final class RejectAgentPreferences: PlannerPreferencesAdapter {
    func load() throws -> DevicePreferences? { nil }
    func save(_ preferences: DevicePreferences?) throws { throw PlannerError("Sample storage failure.") }
}

@MainActor
private final class AgentConnectionFixture {
    let root: URL
    let store: PlannerStore
    let feedback = SettingsFailureFeedback()
    var statuses = Dictionary(
        uniqueKeysWithValues: AgentConnector.App.allCases.map { ($0, AgentConnector.Status.notConnected) })
    var binding: Binding<[AgentConnector.App: AgentConnector.Status]> {
        Binding(get: { self.statuses }, set: { self.statuses = $0 })
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        try file.save(Planner())
        store = PlannerStore(file: file, watching: false)
        for app in AgentConnector.App.allCases {
            try Data(#"{"preserve":"sample setting","mcpServers":{"other":{"command":"sample"}}}"#.utf8)
                .write(to: url(app))
        }
    }

    func url(_ app: AgentConnector.App) -> URL { root.appendingPathComponent("\(app.rawValue).json") }
    func readStatus(_ app: AgentConnector.App) -> AgentConnector.Status {
        AgentConnector.jsonHasServer(url(app), path: ["mcpServers"]) ? .connected : .notConnected
    }
    @discardableResult
    func connect(_ app: AgentConnector.App) throws -> String {
        try AgentConnector.addServer(to: url(app))
        return "Restart the sample app."
    }
    func disconnect(_ app: AgentConnector.App) throws { try AgentConnector.removeServer(from: url(app)) }
    func close() { try? FileManager.default.removeItem(at: root) }
}
