import AppKit
import SwiftUI
import XCTest
@testable import PerchApp
@testable import PlannerCore

/// The production detail surface and agent controls, with isolated storage and no system integrations.
final class SettingsErrorFeedbackTests: XCTestCase {
    @MainActor
    func testLoginItemFailureIsVisibleAndRetriesTheRequestedValue() async throws {
        let fixture = try SettingsFailureFixture()
        defer { fixture.close() }
        let original = try Data(contentsOf: fixture.store.file.url)
        await settle()
        try press("Change login item", in: fixture.window)
        await settle()
        XCTAssertEqual(fixture.loginRequests, [true])
        XCTAssertFalse(fixture.loginEnabled)
        let error = try XCTUnwrap(fixture.store.lastError)
        XCTAssertEqual(error, .loginItem("Synthetic login failure"))
        assertVisible(error, in: fixture.window)
        XCTAssertEqual(SettingsErrorRow(error: error).status.tone, .danger)
        XCTAssertEqual(fixture.draft, "Keep this form text")
        XCTAssertEqual(fixture.pane, .general)
        try assertRetry(in: fixture.window)

        // Switching the form does not remove its parent's failure or retained draft.
        fixture.pane = .focus
        await settle()
        assertVisible(error, in: fixture.window)
        XCTAssertEqual(fixture.draft, "Keep this form text")
        fixture.shouldFail = false
        try press("Repeat", in: fixture.window)
        await settle()
        XCTAssertEqual(fixture.loginRequests, [true, true])
        XCTAssertTrue(fixture.loginEnabled)
        XCTAssertNil(fixture.store.lastError)
        XCTAssertEqual(fixture.pane, .focus)
        XCTAssertEqual(try Data(contentsOf: fixture.store.file.url), original)
        XCTAssertTrue(named("Repeat", in: fixture.window).isEmpty)
    }

    @MainActor
    func testDisconnectFailureIsVisibleAndKeepsTheConnectedAppList() async throws {
        let fixture = try SettingsFailureFixture(pane: .agents)
        defer { fixture.close() }
        let original = try Data(contentsOf: fixture.store.file.url)
        await settle()
        let statuses = fixture.statuses
        try press("Disconnect", in: fixture.window)
        await settle()
        XCTAssertEqual(fixture.disconnectRequests, [.claudeApp])
        XCTAssertEqual(fixture.statuses, statuses)
        XCTAssertEqual(fixture.pane, .agents)
        let error = try XCTUnwrap(fixture.store.lastError)
        XCTAssertEqual(error, .planner("Synthetic disconnect failure"))
        assertVisible(error, in: fixture.window)
        XCTAssertEqual(SettingsErrorRow(error: error).status.tone, .danger)
        try assertRetry(in: fixture.window)
        XCTAssertFalse(named("Connected", in: fixture.window).isEmpty)

        fixture.pane = .focus
        await settle()
        assertVisible(error, in: fixture.window)
        fixture.pane = .agents
        await settle()
        XCTAssertEqual(fixture.statuses, statuses)
        fixture.shouldFail = false
        try press("Repeat", in: fixture.window)
        await settle()
        XCTAssertEqual(fixture.disconnectRequests, [.claudeApp, .claudeApp])
        XCTAssertEqual(fixture.statuses[.claudeApp], .notConnected)
        XCTAssertEqual(fixture.statuses[.cursor], statuses[.cursor])
        XCTAssertEqual(fixture.statuses[.claudeCode], statuses[.claudeCode])
        XCTAssertNil(fixture.store.lastError)
        XCTAssertEqual(fixture.draft, "Keep this form text")
        XCTAssertEqual(try Data(contentsOf: fixture.store.file.url), original)
    }

    @MainActor
    func testExportFailureIsVisibleAndRetriesTheSameDestination() async throws {
        let fixture = try SettingsFailureFixture(pane: .system)
        defer { fixture.close() }
        let original = try Data(contentsOf: fixture.store.file.url)
        // A real filesystem failure, not a simulated successful export.
        try Data("not a directory".utf8).write(to: fixture.exportParent)
        await settle()
        try press("Export fixture", in: fixture.window)
        await settle()
        let error = try XCTUnwrap(fixture.store.lastError)
        assertVisible(error, in: fixture.window)
        XCTAssertEqual(SettingsErrorRow(error: error).status.tone, .danger)
        try assertRetry(in: fixture.window)
        XCTAssertEqual(fixture.pane, .system)
        XCTAssertEqual(fixture.draft, "Keep this form text")
        XCTAssertEqual(try Data(contentsOf: fixture.store.file.url), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.exportURL.path))

        fixture.pane = .focus
        await settle()
        assertVisible(error, in: fixture.window)
        try FileManager.default.removeItem(at: fixture.exportParent)
        try FileManager.default.createDirectory(at: fixture.exportParent, withIntermediateDirectories: true)
        try press("Repeat", in: fixture.window)
        await settle()
        XCTAssertNil(fixture.store.lastError)
        XCTAssertEqual(try Data(contentsOf: fixture.exportURL), original)
        XCTAssertEqual(try Data(contentsOf: fixture.store.file.url), original)
        XCTAssertEqual(fixture.pane, .focus)
        XCTAssertEqual(fixture.draft, "Keep this form text")
    }

    @MainActor
    func testPermissionAndUnrelatedErrorsHaveNoInventedRetry() async throws {
        let fixture = try SettingsFailureFixture()
        defer { fixture.close() }
        await settle()
        fixture.store.lastError = .remindersPermission
        await settle()
        assertVisible(.remindersPermission, in: fixture.window)
        XCTAssertEqual(SettingsErrorRow(error: .remindersPermission).status.tone, .danger)
        XCTAssertTrue(named("Repeat", in: fixture.window).isEmpty)
        try press("Change login item", in: fixture.window)
        await settle()
        try assertRetry(in: fixture.window)
        fixture.store.lastError = .planner("A different operation failed")
        await settle()
        assertVisible(.planner("A different operation failed"), in: fixture.window)
        XCTAssertTrue(named("Repeat", in: fixture.window).isEmpty)
        XCTAssertEqual(fixture.loginRequests, [true])
    }

    @MainActor
    private func assertVisible(
        _ error: PerchAppError, in window: NSWindow, file: StaticString = #filePath, line: UInt = #line
    ) {
        let labels = named(error.perchPresentationDetail, in: window)
        XCTAssertFalse(labels.isEmpty, "Settings must render its error: \(error)", file: file, line: line)
        let visible = window.convertToScreen(window.contentView!.bounds)
        for label in labels {
            let frame = (label as? NSAccessibilityProtocol)?.accessibilityFrame() ?? .zero
            XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
            XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
            XCTAssertTrue(
                visible.insetBy(dx: -1, dy: -1).contains(frame), "Error is inside Settings, not the notch", file: file,
                line: line)
        }
    }

    @MainActor
    private func assertRetry(in window: NSWindow) throws {
        let retry = try XCTUnwrap(named("Repeat", in: window).first)
        XCTAssertEqual(attribute(retry, "accessibilityRole") as? String, "AXButton")
        XCTAssertEqual(attribute(retry, "accessibilityIdentifier") as? String, "settings.error.retry")
    }

    @MainActor
    private func press(_ title: String, in window: NSWindow) throws {
        let buttons = named(title, in: window).filter { attribute($0, "accessibilityRole") as? String == "AXButton" }
        XCTAssertEqual(buttons.count, 1, "Expected exactly one \(title) button")
        let button = try XCTUnwrap(buttons.first)
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let implementation = try XCTUnwrap(button.responds(to: selector) ? button.method(for: selector) : nil)
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(implementation, to: Press.self)(button, selector))
    }

    @MainActor
    private func named(_ text: String, in window: NSWindow) -> [NSObject] {
        nodes(window.contentView!).filter {
            attribute($0, "accessibilityLabel") as? String == text
                || attribute($0, "accessibilityValue") as? String == text
                || ($0 as? NSButton)?.title == text
        }
    }

    @MainActor
    private func nodes(_ root: NSObject) -> [NSObject] {
        var result: [NSObject] = [], visited = Set<ObjectIdentifier>()
        @MainActor func visit(_ node: NSObject, depth: Int) {
            guard depth < 80, result.count < 10000, visited.insert(ObjectIdentifier(node)).inserted else { return }
            result.append(node)
            if let view = node as? NSView { for child in view.subviews { visit(child, depth: depth + 1) } }
            for key in ["accessibilityChildren", "accessibilityContents"] {
                for child in attribute(node, key) as? [NSObject] ?? [] { visit(child, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return result
    }

    @MainActor
    private func attribute(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard node.responds(to: selector) else { return nil }
        return node.perform(selector)?.takeUnretainedValue()
    }

    @MainActor
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
    }
}

@MainActor
private final class SettingsFailureFixture: ObservableObject {
    let root: URL
    let store: PlannerStore
    let feedback = SettingsFailureFeedback()
    let window: NSWindow
    @Published var pane: SettingsView.Pane
    @Published var draft = "Keep this form text"
    @Published var statuses: [AgentConnector.App: AgentConnector.Status] = [
        .claudeCode: .notInstalled, .claudeApp: .connected, .cursor: .notInstalled,
    ]
    var shouldFail = true
    var loginEnabled = false
    var loginRequests: [Bool] = []
    var disconnectRequests: [AgentConnector.App] = []
    var exportParent: URL { root.appendingPathComponent("exports") }
    var exportURL: URL { exportParent.appendingPathComponent("chosen.json") }
    private let oldData: String?

    init(pane: SettingsView.Pane = .general) throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("planner.json")
        oldData = ProcessInfo.processInfo.environment["PERCH_DATA"]
        setenv("PERCH_DATA", url.path, 1)
        let file = PlannerFile(url: url, preferences: MemoryPlannerPreferences())
        var planner = Planner()
        planner.preferences.defaultFocusMinutes = 35
        try file.save(planner)
        store = PlannerStore(file: file, watching: false)
        self.pane = pane
        window = NSWindow(
            contentRect: NSRect(x: 20, y: 20, width: 440, height: 520), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: SettingsFailureFixtureView(fixture: self)
                .environmentObject(store).environment(\.accessibilityEnabled, true))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func changeLoginItem() {
        feedback.updateLoginItem(true, store: store) { [self] enabled in
            loginRequests.append(enabled)
            if shouldFail { throw PlannerError("Synthetic login failure") }
            loginEnabled = enabled
        }
    }

    func disconnect(_ app: AgentConnector.App) throws {
        disconnectRequests.append(app)
        if shouldFail { throw PlannerError("Synthetic disconnect failure") }
    }

    func status(_ app: AgentConnector.App) -> AgentConnector.Status {
        if app == .claudeApp { return shouldFail ? .connected : .notConnected }
        return .notInstalled
    }

    func close() {
        window.contentView = nil
        window.close()
        if let oldData { setenv("PERCH_DATA", oldData, 1) } else { unsetenv("PERCH_DATA") }
        try? FileManager.default.removeItem(at: root)
    }
}

private struct SettingsFailureFixtureView: View {
    @ObservedObject var fixture: SettingsFailureFixture
    var body: some View {
        // Same stable parent as SettingsView; no notch or permission-backed Services is constructed.
        SettingsDetail(feedback: fixture.feedback) {
            Form {
                if fixture.pane == .agents {
                    AgentsSettings(
                        statuses: $fixture.statuses, feedback: fixture.feedback,
                        readStatus: fixture.status, disconnect: fixture.disconnect)
                } else {
                    Section {
                        Text(fixture.pane.title)
                        TextField("Draft", text: $fixture.draft)
                        Text("35 min")
                        Button("Change login item", action: fixture.changeLoginItem)
                        Button("Export fixture") {
                            fixture.feedback.exportBackup(to: fixture.exportURL, store: fixture.store)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .font(Theme.body).foregroundStyle(Theme.text)
        .buttonStyle(PillStyle())
    }
}
