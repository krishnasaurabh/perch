import AppKit
import SwiftUI
import XCTest
@testable import PerchApp
@testable import PlannerCore

@MainActor
final class DashboardPaneHostingTests: XCTestCase {
    func testClosingAnEditingHistoryWindowAllowsAFreshProjectsWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlannerStore(
            file: PlannerFile(url: directory.appendingPathComponent("planner.json")), watching: false)
        let previousPolicy = NSApplication.shared.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer {
            WindowHost.windows["dashboard"]?.close()
            NSApp.setActivationPolicy(previousPolicy)
        }
        _ = store.send(.createProject("Window lifecycle fixture"))
        for tab in [DashboardView.Tab.history, .projects, .history, .projects] {
            DashboardWindow.show(store: store, tab: tab)
            do {
                let window = try XCTUnwrap(WindowHost.windows["dashboard"])
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 100_000_000)
                if tab == .history {
                    let search = try XCTUnwrap(
                        Self.views(try XCTUnwrap(window.contentView))
                            .compactMap { $0 as? DashboardSearchField }.first)
                    XCTAssertTrue(window.makeFirstResponder(search))
                    let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)
                    editor.insertText("alpha", replacementRange: NSRange(location: 0, length: 0))
                    try await Task.sleep(nanoseconds: 100_000_000)
                    XCTAssertEqual(search.stringValue, "alpha")
                }
                window.close()
                XCTAssertNil(WindowHost.windows["dashboard"], "Close retires this window identity synchronously")
                // A deferred layout/paint callback must not rebuild a closed window's loop.
                window.initialFirstResponder = nil
                DashboardKeyLoop.install(in: window)
                XCTAssertNil(window.initialFirstResponder)
                try await Task.sleep(nanoseconds: 100_000_000)
                XCTAssertNil(window.contentView, "Detach the hosted graph before the owning window is released")
            }
            // Release the production window before mounting the next section.
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    func testRootUpdatesKeepListStateAndForwardStoreAndEnvironment() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlannerStore(
            file: PlannerFile(url: directory.appendingPathComponent("planner.json")), watching: false)
        let report = PaneReport()
        var environment = EnvironmentValues()
        environment.colorScheme = .light
        environment.dynamicTypeSize = .large
        let controller = NSHostingController(
            rootView: DashboardPaneRoot(content: PaneStateProbe(report: report), store: store, environment: environment)
        )
        controller.sizingOptions = [.intrinsicContentSize]
        controller.view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let identity = try XCTUnwrap(report.identity)
        XCTAssertTrue(report.store === store)
        XCTAssertEqual(report.scheme, .light)
        XCTAssertEqual(report.textSize, .large)
        XCTAssertTrue(report.accessibilityEnabled)

        environment.colorScheme = .dark
        environment.dynamicTypeSize = .accessibility3
        controller.rootView = DashboardPaneRoot(
            content: PaneStateProbe(report: report), store: store, environment: environment)
        controller.view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(report.identity, identity, "Appearance updates must not recreate the list's local state")
        XCTAssertTrue(report.store === store)
        XCTAssertEqual(report.scheme, .dark)
        XCTAssertEqual(report.textSize, .accessibility3)
        XCTAssertTrue(report.accessibilityEnabled)

        let wide = controller.sizeThatFits(in: CGSize(width: 640, height: CGFloat.greatestFiniteMagnitude))
        let narrow = controller.sizeThatFits(in: CGSize(width: 240, height: CGFloat.greatestFiniteMagnitude))
        XCTAssertEqual(wide.width, 640, accuracy: 1)
        XCTAssertEqual(narrow.width, 240, accuracy: 1)
        XCTAssertGreaterThan(narrow.height, wide.height, "The scroll document must grow when its text wraps")
        XCTAssertTrue(narrow.height.isFinite)
    }
}

@MainActor
private final class PaneReport {
    var identity: UUID?
    weak var store: PlannerStore?
    var scheme: ColorScheme?
    var textSize: DynamicTypeSize?
    var accessibilityEnabled = false
}

private struct PaneStateProbe: View {
    let report: PaneReport
    @State private var identity = UUID()
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityEnabled) private var accessibilityEnabled

    var body: some View {
        Text(String(repeating: "A finished task with a wrapping title. ", count: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                PaneReportView(
                    report: report, identity: identity, store: store, scheme: scheme,
                    textSize: textSize, accessibilityEnabled: accessibilityEnabled)
            }
    }
}

private struct PaneReportView: NSViewRepresentable {
    let report: PaneReport
    let identity: UUID
    let store: PlannerStore
    let scheme: ColorScheme
    let textSize: DynamicTypeSize
    let accessibilityEnabled: Bool

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        report.identity = identity
        report.store = store
        report.scheme = scheme
        report.textSize = textSize
        report.accessibilityEnabled = accessibilityEnabled
    }
}
