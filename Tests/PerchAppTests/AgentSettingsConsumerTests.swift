import AppKit
import SwiftUI
import XCTest
@testable import PerchApp
@testable import PlannerCore

final class AgentSettingsConsumerTests: XCTestCase {
    @MainActor
    func testConnectionRetryPublishesSuccessGuidanceForEveryApp() async throws {
        for app in AgentConnector.App.allCases {
            let fixture = try AgentConsumerFixture()
            defer { fixture.close() }
            let feedback = SettingsFailureFeedback()
            var status = AgentConnector.Status.notConnected
            var displayedMessage: String?
            var attempts = 0
            let guidance = "Restart the sample app."
            let statuses = Binding<[AgentConnector.App: AgentConnector.Status]>(
                get: { [app: status] }, set: { status = $0[app] ?? .notConnected })
            let message = Binding<String?>(get: { displayedMessage }, set: { displayedMessage = $0 })
            let result = AgentsSettings.connectAgent(
                app, store: fixture.store, statuses: statuses, feedback: feedback,
                readStatus: { _ in status },
                connect: { _ in
                    attempts += 1
                    if attempts < 3 { throw PlannerError("Sample connection failure.") }
                    status = .connected
                    return guidance
                }, message: message)
            XCTAssertNil(result)
            XCTAssertNil(displayedMessage)
            let firstError = try XCTUnwrap(fixture.store.lastError)
            feedback.retry(firstError)
            XCTAssertEqual(attempts, 2)
            XCTAssertNil(displayedMessage, "A failed retry must not publish success guidance")
            let secondError = try XCTUnwrap(fixture.store.lastError)
            feedback.retry(secondError)
            XCTAssertEqual(attempts, 3)
            XCTAssertNil(fixture.store.lastError)
            XCTAssertEqual(status, .connected)
            XCTAssertEqual(displayedMessage, guidance, "Retry writes to the same state used by the visible message")
            feedback.retry(secondError)
            XCTAssertEqual(attempts, 3, "A completed retry cannot replay the connector")
        }
    }

    @MainActor
    func testUnconfirmedConnectionDoesNotPublishGuidance() async throws {
        let fixture = try AgentConsumerFixture()
        defer { fixture.close() }
        var displayedMessage: String?
        let result = AgentsSettings.connectAgent(
            .cursor, store: fixture.store, statuses: .constant([.cursor: .notConnected]),
            feedback: SettingsFailureFeedback(), readStatus: { _ in .notConnected },
            connect: { _ in "Restart the sample app." },
            message: Binding(get: { displayedMessage }, set: { displayedMessage = $0 }))
        XCTAssertNil(result)
        XCTAssertNil(displayedMessage)
        XCTAssertNotNil(fixture.store.lastError)
    }

    @MainActor
    func testExistingTaskAttributionAndHelpFollowSwitchWithoutRemovingIdentity() async throws {
        let fixture = try AgentConsumerFixture()
        defer { fixture.close() }
        let task = try XCTUnwrap(fixture.store.planner.tasks.first)
        let model = NotchModel()
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        defer { app.setActivationPolicy(originalPolicy) }
        // Exercise each production consumer, not a copy of the preference predicate.
        for view in [AnyView(TaskRow(task: task)), AnyView(DashboardTaskLine(task: task))] {
            let host = NSHostingView(
                rootView: view.environmentObject(fixture.store).environmentObject(model)
                    .environment(\.accessibilityEnabled, true))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 200),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.contentView = nil; window.close() }
            for enabled in [true, false, true] {
                AgentSettingsPreference.showAgentAttribution.binding(in: fixture.store).wrappedValue = enabled
                XCTAssertNil(fixture.store.lastError)
                try await assertAttribution(enabled, in: window)
                let persisted = try fixture.file.load()
                XCTAssertEqual(persisted.preferences.showAgentAttribution, enabled)
                XCTAssertEqual(persisted.tasks.first?.agentID, task.agentID)
                let restarted = PlannerStore(file: fixture.file, watching: false)
                XCTAssertEqual(restarted.prefs.showAgentAttribution, enabled)
                XCTAssertEqual(restarted.planner.tasks.first?.agentID, task.agentID)
            }
        }
    }

    @MainActor
    private func assertAttribution(_ visible: Bool, in window: NSWindow) async throws {
        let label = AppL10n.format("Via %@", "Sample")
        let rawAgent = "sample-agent"
        let deadline = ContinuousClock.now + .seconds(3)
        var texts: [String] = []
        repeat {
            try await Task.sleep(for: .milliseconds(40))
            window.contentView?.layoutSubtreeIfNeeded()
            texts = accessibilityTexts(window)
            let hasLabel = texts.contains(where: { $0.contains(label) })
            let hasHelp = texts.contains(where: { $0.contains(rawAgent) })
            if hasLabel == visible && hasHelp == visible { return }
        } while ContinuousClock.now < deadline
        XCTFail("Attribution label/help visibility should be \(visible). Observed: \(texts)")
    }

    @MainActor
    private func accessibilityTexts(_ root: NSObject) -> [String] {
        var seen = Set<ObjectIdentifier>()
        func attribute(_ node: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
        }
        func walk(_ node: NSObject) -> [String] {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            var children = ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"]
                .flatMap { (attribute(node, $0) as? [NSObject]) ?? [] }
            if let view = node as? NSView { children += view.subviews }
            if let window = node as? NSWindow, let content = window.contentView { children.append(content) }
            let texts = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityHelp"]
                .compactMap { attribute(node, $0) as? String }
            return texts + children.flatMap(walk)
        }
        return walk(root)
    }
}

@MainActor
private final class AgentConsumerFixture {
    let root: URL
    let file: PlannerFile
    let store: PlannerStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        file = PlannerFile(url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var planner = Planner()
        planner.preferences.resetHour = 0
        planner.tasks = [
            PlanTask(title: "Inspect seedlings", day: DayKey(now), createdAt: now, agentID: "sample-agent")
        ]
        try file.save(planner)
        store = PlannerStore(file: file, now: { now }, watching: false)
    }

    func close() { try? FileManager.default.removeItem(at: root) }
}
