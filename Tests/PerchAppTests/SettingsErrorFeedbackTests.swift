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
        fixture.pane = .notch
        await settle()
        assertVisible(error, in: fixture.window)
        XCTAssertEqual(fixture.draft, "Keep this form text")
        fixture.shouldFail = false
        try press("Retry", in: fixture.window)
        await settle()
        XCTAssertEqual(fixture.loginRequests, [true, true])
        XCTAssertTrue(fixture.loginEnabled)
        XCTAssertNil(fixture.store.lastError)
        XCTAssertEqual(fixture.pane, .notch)
        XCTAssertEqual(try Data(contentsOf: fixture.store.file.url), original)
        XCTAssertTrue(named("Retry", in: fixture.window).isEmpty)
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

        fixture.pane = .notch
        await settle()
        assertVisible(error, in: fixture.window)
        fixture.pane = .agents
        await settle()
        XCTAssertEqual(fixture.statuses, statuses)
        fixture.shouldFail = false
        try press("Retry", in: fixture.window)
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
    func testAgentStatusesRefreshOnReentryAfterExternalChanges() async throws {
        let fixture = try SettingsFailureFixture(pane: .agents)
        defer { fixture.close() }
        await settle()
        XCTAssertEqual(fixture.statuses[.claudeCode], .notInstalled)
        XCTAssertEqual(fixture.statuses[.cursor], .notInstalled)

        fixture.pane = .notch
        await settle()
        fixture.externalStatuses[.claudeCode] = .notConnected
        fixture.externalStatuses[.cursor] = .connected
        fixture.pane = .agents
        await settle()
        XCTAssertEqual(fixture.statuses[.claudeCode], .notConnected)
        XCTAssertEqual(fixture.statuses[.cursor], .connected)
        XCTAssertFalse(named("Connect", in: fixture.window).isEmpty)

        fixture.pane = .notch
        await settle()
        fixture.externalStatuses[.claudeCode] = .connected
        fixture.externalStatuses[.cursor] = .notConnected
        fixture.pane = .agents
        await settle()
        XCTAssertEqual(fixture.statuses[.claudeCode], .connected)
        XCTAssertEqual(fixture.statuses[.cursor], .notConnected)
    }

    @MainActor
    func testFailedDisconnectRetainsOnlyItsAppOnReentry() async throws {
        let fixture = try SettingsFailureFixture(pane: .agents)
        defer { fixture.close() }
        await settle()
        try press("Disconnect", in: fixture.window)
        await settle()
        let error = try XCTUnwrap(fixture.store.lastError)

        fixture.pane = .notch
        await settle()
        fixture.externalStatuses[.claudeCode] = .notConnected
        fixture.externalStatuses[.cursor] = .connected
        fixture.pane = .agents
        await settle()
        XCTAssertEqual(fixture.statuses[.claudeApp], .connected)
        XCTAssertEqual(fixture.statuses[.claudeCode], .notConnected)
        XCTAssertEqual(fixture.statuses[.cursor], .connected)
        XCTAssertEqual(fixture.disconnectRequests, [.claudeApp])
        assertVisible(error, in: fixture.window)
        try assertRetry(in: fixture.window)
    }

    @MainActor
    func testClearedExportRetryDoesNotOwnSameValuePreferenceFailure() async throws {
        let fixture = try SettingsFailureFixture(pane: .data)
        defer { fixture.close() }
        var exportAttempts = 0
        fixture.feedback.exportBackup(to: fixture.exportURL, store: fixture.store) { _ in
            exportAttempts += 1
            if exportAttempts == 1 { throw PlannerStorageBusy() }
        }
        let exportError = try XCTUnwrap(fixture.store.lastError)
        XCTAssertTrue(fixture.feedback.canRetry(exportError))
        await settle()
        try assertRetry(in: fixture.window)

        fixture.store.updatePrefs { $0.defaultFocusMinutes = 40 }
        XCTAssertNil(fixture.store.lastError)
        // No render or run-loop turn between these events: value-based onChange is insufficient.
        fixture.store.apply { _ -> Void in throw PlannerStorageBusy() }
        let preferenceError = try XCTUnwrap(fixture.store.lastError)
        XCTAssertEqual(preferenceError, exportError)
        XCTAssertFalse(fixture.feedback.canRetry(preferenceError))
        fixture.feedback.retry(preferenceError)
        XCTAssertEqual(exportAttempts, 1)
        XCTAssertEqual(fixture.store.lastError, preferenceError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.exportURL.path))
        await settle()
        assertVisible(preferenceError, in: fixture.window)
        XCTAssertTrue(named("Retry", in: fixture.window).isEmpty)
    }

    @MainActor
    func testSameValueFailureSupersedesExportRetryWithoutClearingFirst() async throws {
        let fixture = try SettingsFailureFixture()
        defer { fixture.close() }
        var exportAttempts = 0
        fixture.feedback.exportBackup(to: fixture.exportURL, store: fixture.store) { _ in
            exportAttempts += 1
            if exportAttempts == 1 { throw PlannerStorageBusy() }
        }
        let exportError = try XCTUnwrap(fixture.store.lastError)
        XCTAssertTrue(fixture.feedback.canRetry(exportError))
        fixture.store.apply { _ -> Void in throw PlannerStorageBusy() }
        XCTAssertEqual(fixture.store.lastError, exportError)
        XCTAssertFalse(fixture.feedback.canRetry(exportError))
        fixture.feedback.retry(exportError)
        XCTAssertEqual(exportAttempts, 1)
        XCTAssertEqual(fixture.store.lastError, exportError)
        await settle()
        XCTAssertTrue(named("Retry", in: fixture.window).isEmpty)
    }

    @MainActor
    func testExportFailureIsVisibleAndRetriesTheSameDestination() async throws {
        let fixture = try SettingsFailureFixture(pane: .data)
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
        XCTAssertEqual(fixture.pane, .data)
        XCTAssertEqual(fixture.draft, "Keep this form text")
        XCTAssertEqual(try Data(contentsOf: fixture.store.file.url), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.exportURL.path))

        fixture.pane = .notch
        await settle()
        assertVisible(error, in: fixture.window)
        try FileManager.default.removeItem(at: fixture.exportParent)
        try FileManager.default.createDirectory(at: fixture.exportParent, withIntermediateDirectories: true)
        try press("Retry", in: fixture.window)
        await settle()
        XCTAssertNil(fixture.store.lastError)
        let exported = try PlannerFile(url: fixture.exportURL, preferences: MemoryPlannerPreferences()).load()
        XCTAssertEqual(exported.tasks, fixture.store.planner.tasks)
        XCTAssertEqual(exported.notes, fixture.store.planner.notes)
        XCTAssertEqual(try Data(contentsOf: fixture.store.file.url), original)
        XCTAssertEqual(fixture.pane, .notch)
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
        XCTAssertTrue(named("Retry", in: fixture.window).isEmpty)
        try press("Change login item", in: fixture.window)
        await settle()
        try assertRetry(in: fixture.window)
        fixture.store.lastError = .planner("A different operation failed")
        await settle()
        assertVisible(.planner("A different operation failed"), in: fixture.window)
        XCTAssertTrue(named("Retry", in: fixture.window).isEmpty)
        XCTAssertEqual(fixture.loginRequests, [true])
    }

    @MainActor
    private func assertVisible(
        _ error: PerchAppError, in window: NSWindow, file: StaticString = #filePath, line: UInt = #line
    ) {
        let labels = named(error.perchPresentationDetail, in: window)
        XCTAssertFalse(labels.isEmpty, "Settings must render its error: \(error)", file: file, line: line)
        XCTAssertEqual(window.contentView!.bounds.width, 440, accuracy: 1, file: file, line: line)
        XCTAssertEqual(window.contentView!.bounds.height, 520, accuracy: 1, file: file, line: line)
        let visible = window.convertToScreen(window.contentView!.bounds)
        for label in labels {
            let frame = (label.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
            print("Settings error frame: \(frame); viewport: \(visible); text: \(error.perchPresentationDetail)")
            XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
            XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
            XCTAssertTrue(
                visible.insetBy(dx: -1, dy: -1).contains(frame), "Error is inside Settings, not the notch", file: file,
                line: line)
        }
    }

    @MainActor
    private func assertRetry(in window: NSWindow) throws {
        let retry = try XCTUnwrap(named("Retry", in: window).first)
        XCTAssertEqual(attribute(retry, "accessibilityRole") as? String, "AXButton")
        XCTAssertEqual(attribute(retry, "accessibilityIdentifier") as? String, "settings.error.retry")
    }

    @MainActor
    private func press(_ title: String, in window: NSWindow) throws {
        let buttons = named(title, in: window).filter { attribute($0, "accessibilityRole") as? String == "AXButton" }
        let diagnostics = nodes(window.contentView!).map {
            "\(type(of: $0)) role=\(attribute($0, "accessibilityRole") ?? "?") label=\(attribute($0, "accessibilityLabel") ?? "?") title=\(attribute($0, "accessibilityTitle") ?? "?") value=\(attribute($0, "accessibilityValue") ?? "?")"
        }.joined(separator: "\n")
        XCTAssertEqual(buttons.count, 1, "Expected exactly one \(title) button\n\(diagnostics)")
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
                || attribute($0, "accessibilityTitle") as? String == text
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
            for key in ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"] {
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
    var externalStatuses: [AgentConnector.App: AgentConnector.Status] = [:]
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
        planner.tasks = [
            PlanTask(
                title: "Inspect synthetic seedlings", day: nil, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                notes: "Retain this task")
        ]
        try file.save(planner)
        store = PlannerStore(file: file, watching: false)
        self.pane = pane
        window = NSWindow(
            contentRect: NSRect(x: 20, y: 20, width: 440, height: 520), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(
            rootView: SettingsFailureFixtureView(fixture: self)
                .environmentObject(store).environment(\.accessibilityEnabled, true))
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(NSSize(width: 440, height: 520))
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
        if let external = externalStatuses[app] { return external }
        if app == .claudeApp { return disconnectRequests.isEmpty ? .connected : .notConnected }
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
            VStack(alignment: .leading, spacing: 12) {
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
            .padding(12)
        }
        .font(Theme.body).foregroundStyle(Theme.text)
        .buttonStyle(PillStyle())
    }
}
