import AppKit
import SwiftUI
import XCTest
@testable import PerchApp
@testable import PlannerCore

/// Exercise production controls across the same pane-identity boundary as SettingsView.
final class AgentGuidanceLifetimeTests: XCTestCase {
    @MainActor
    func testRetryGuidanceReachesTheRecreatedPaneForEveryApp() async throws {
        for app in AgentConnector.App.allCases {
            let fixture = try AgentGuidanceFixture(app: app)
            defer { fixture.close() }
            try await press("settings.agents.\(app.rawValue).connect", in: fixture.window)
            XCTAssertEqual(fixture.attempts, 1)
            XCTAssertEqual(fixture.statuses[app], .notConnected)
            XCTAssertNotNil(fixture.store.lastError)

            try await leaveAndReturn(fixture)
            // A second failure must also preserve the retry and not present success guidance.
            try await press("settings.error.retry", in: fixture.window)
            XCTAssertEqual(fixture.attempts, 2)
            XCTAssertFalse(texts(in: fixture.window).contains(fixture.guidance))
            try await leaveAndReturn(fixture)

            fixture.shouldFail = false
            try await press("settings.error.retry", in: fixture.window)
            try await waitUntil { texts(in: fixture.window).contains(fixture.guidance) }
            XCTAssertEqual(fixture.attempts, 3)
            XCTAssertEqual(fixture.statuses[app], .connected)
            XCTAssertNil(fixture.store.lastError)
            XCTAssertTrue(texts(in: fixture.window).contains(AppL10n.text("Connected")))
            XCTAssertTrue(nodes(in: fixture.window).contains { identifier($0) == fixture.disconnectID })
            XCTAssertFalse(nodes(in: fixture.window).contains { identifier($0) == "settings.error.retry" })
            XCTAssertTrue(AgentConnector.jsonHasServer(fixture.config, path: ["mcpServers"]))
            try await leaveAndReturn(fixture, guidanceVisible: true)
            XCTAssertTrue(texts(in: fixture.window).contains(fixture.guidance))
            XCTAssertEqual(try Data(contentsOf: fixture.store.file.url), fixture.originalPlanner)

            try await press(fixture.disconnectID, in: fixture.window)
            try await waitUntil { !texts(in: fixture.window).contains(fixture.guidance) }
            XCTAssertEqual(fixture.statuses[app], .notConnected)
            XCTAssertFalse(AgentConnector.jsonHasServer(fixture.config, path: ["mcpServers"]))
        }
    }

    @MainActor
    func testRetryWhileAwayPublishesGuidanceOnReturnWithoutLeakingToAnotherWindow() async throws {
        let fixture = try AgentGuidanceFixture(app: .cursor)
        defer { fixture.close() }
        try await press("settings.agents.cursor.connect", in: fixture.window)
        try await press("test.general", in: fixture.window)
        try await waitUntil { !texts(in: fixture.window).contains(AppL10n.text("Connected apps")) }
        fixture.shouldFail = false
        try await press("settings.error.retry", in: fixture.window)
        XCTAssertNil(fixture.store.lastError)
        XCTAssertEqual(fixture.statuses[.cursor], .connected)
        try await press("test.agents", in: fixture.window)
        try await waitUntil { texts(in: fixture.window).contains(fixture.guidance) }

        let otherWindow = try AgentGuidanceFixture(app: .cursor)
        defer { otherWindow.close() }
        try await waitUntil { texts(in: otherWindow.window).contains(AppL10n.text("Connected apps")) }
        XCTAssertFalse(texts(in: otherWindow.window).contains(fixture.guidance))
        XCTAssertEqual(otherWindow.attempts, 0)
        XCTAssertEqual(otherWindow.statuses[.cursor], .notConnected)
    }

    @MainActor
    private func leaveAndReturn(_ fixture: AgentGuidanceFixture, guidanceVisible: Bool = false) async throws {
        try await press("test.general", in: fixture.window)
        try await waitUntil { !texts(in: fixture.window).contains(AppL10n.text("Connected apps")) }
        XCTAssertEqual(fixture.store.lastError != nil, !guidanceVisible)
        try await press("test.agents", in: fixture.window)
        try await waitUntil { texts(in: fixture.window).contains(AppL10n.text("Connected apps")) }
        try await waitUntil { texts(in: fixture.window).contains(fixture.guidance) == guidanceVisible }
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(condition(), "The hosted Settings state did not settle")
    }

    @MainActor
    private func press(_ id: String, in window: NSWindow) async throws {
        try await waitUntil { nodes(in: window).contains { identifier($0) == id } }
        let controls = nodes(in: window).filter {
            identifier($0) == id && attribute($0, "accessibilityRole") as? String == "AXButton"
        }
        if controls.count != 1 { print(diagnostics(in: window)) }
        XCTAssertEqual(controls.count, 1, "Expected one accessible action for \(id)")
        let control = try XCTUnwrap(controls.first)
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let implementation = try XCTUnwrap(control.responds(to: selector) ? control.method(for: selector) : nil)
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(implementation, to: Press.self)(control, selector))
        await Task.yield()
    }

    @MainActor
    private func identifier(_ object: NSObject) -> String? {
        attribute(object, "accessibilityIdentifier") as? String
    }

    @MainActor
    private func texts(in window: NSWindow) -> Set<String> {
        Set(
            nodes(in: window).flatMap { node in
                ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
                    .compactMap { attribute(node, $0) as? String }
            })
    }

    @MainActor
    private func nodes(in window: NSWindow) -> [NSObject] {
        // SwiftUI's scroll content publishes its semantic nodes during layout.
        // Every read must settle that layout, including reads after pane replacement.
        window.contentView?.layoutSubtreeIfNeeded()
        var result: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        @MainActor func visit(_ node: NSObject) {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return }
            result.append(node)
            if let view = node as? NSView { view.subviews.forEach(visit) }
            for key in ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"] {
                (attribute(node, key) as? [NSObject] ?? []).forEach(visit)
            }
        }
        if let content = window.contentView { visit(content) }
        return result
    }

    @MainActor
    private func diagnostics(in window: NSWindow) -> String {
        let inventory = nodes(in: window).map { node in
            let values = [
                "accessibilityRole", "accessibilityIdentifier", "accessibilityLabel",
                "accessibilityTitle", "accessibilityValue",
            ].map { key in
                "\(key)=\(attribute(node, key) ?? "nil")"
            }.joined(separator: " ")
            let bounds = (node as? NSView).map { String(describing: $0.bounds) } ?? "not a view"
            return "\(type(of: node)) bounds=\(bounds) \(values)"
        }.joined(separator: "\n")
        return "Settings host: visible=\(window.isVisible) key=\(window.isKeyWindow) "
            + "active=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue) "
            + "responder=\(String(describing: window.firstResponder))\n\(inventory)"
    }

    @MainActor
    private func attribute(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
    }
}

@MainActor
private final class AgentGuidanceFixture: ObservableObject {
    let root: URL
    let app: AgentConnector.App
    let store: PlannerStore
    let feedback = SettingsFailureFeedback()
    let window: NSWindow
    private let originalActivationPolicy: NSApplication.ActivationPolicy
    let originalPlanner: Data
    let guidance = "Restart the sample app."
    @Published var pane = SettingsView.Pane.agents
    @Published var statuses: [AgentConnector.App: AgentConnector.Status] = [:]
    var shouldFail = true
    var attempts = 0
    var config: URL { root.appendingPathComponent("connection.json") }
    var disconnectID: String { "settings.agents.\(app.rawValue).disconnect" }

    init(app: AgentConnector.App) throws {
        _ = NSApplication.shared
        originalActivationPolicy = NSApp.activationPolicy()
        self.app = app
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        try file.save(Planner())
        originalPlanner = try Data(contentsOf: file.url)
        store = PlannerStore(file: file, watching: false)
        window = NSWindow(
            contentRect: NSRect(x: 20, y: 20, width: 760, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        NSApp.setActivationPolicy(.accessory)
        let host = NSHostingView(
            rootView: AgentGuidanceFixtureView(fixture: self)
                .environmentObject(store).environment(\.accessibilityEnabled, true))
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(SettingsMetrics.windowSize)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func readStatus(_ candidate: AgentConnector.App) -> AgentConnector.Status {
        guard candidate == app else { return .notInstalled }
        return AgentConnector.jsonHasServer(config, path: ["mcpServers"]) ? .connected : .notConnected
    }

    func connect(_ candidate: AgentConnector.App) throws -> String {
        XCTAssertEqual(candidate, app)
        attempts += 1
        if shouldFail { throw PlannerError("Sample connection failure.") }
        try AgentConnector.addServer(to: config)
        return guidance
    }

    func disconnect(_ candidate: AgentConnector.App) throws {
        XCTAssertEqual(candidate, app)
        try AgentConnector.removeServer(from: config)
    }

    func close() {
        window.contentView = nil
        window.close()
        NSApp.setActivationPolicy(originalActivationPolicy)
        try? FileManager.default.removeItem(at: root)
    }
}

private struct AgentGuidanceFixtureView: View {
    @ObservedObject var fixture: AgentGuidanceFixture

    var body: some View {
        VStack {
            HStack {
                Button("General") { fixture.pane = .general }.accessibilityIdentifier("test.general")
                Button("AI agents") { fixture.pane = .agents }.accessibilityIdentifier("test.agents")
            }
            // Keep the production error/retry parent alive, but recreate pane state on navigation.
            // No permission-backed Services or installed client configuration is touched.
            SettingsDetail(feedback: fixture.feedback) {
                ScrollView {
                    if fixture.pane == .agents {
                        AgentsSettings(
                            statuses: $fixture.statuses, feedback: fixture.feedback,
                            readStatus: fixture.readStatus, disconnect: fixture.disconnect, connect: fixture.connect)
                    } else {
                        Text("General")
                    }
                }
                .id(fixture.pane)
            }
        }
    }
}
