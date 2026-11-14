import AppKit
import PerchUI
import SwiftUI
import XCTest
@testable import PerchApp

final class SettingsShellTests: XCTestCase {
    func testPaneOrderTitlesAndPreviewNames() {
        XCTAssertEqual(SettingsView.Pane.allCases.map(\.rawValue), ["general", "notch", "calendar", "agents", "data"])
        XCTAssertEqual(
            SettingsView.Pane.allCases.map(\.title),
            ["General", "Notch and menu bar", "Calendar and reminders", "AI agents", "Your data"])
        for pane in SettingsView.Pane.allCases {
            XCTAssertEqual(pane.previewTarget, "settings/\(pane.rawValue)")
        }
    }

    func testArrowNavigationStopsAtTheEnds() {
        XCTAssertEqual(SettingsView.Pane.general.moved(by: -1), .general)
        XCTAssertEqual(SettingsView.Pane.general.moved(by: 1), .notch)
        XCTAssertEqual(SettingsView.Pane.calendar.moved(by: -1), .notch)
        XCTAssertEqual(SettingsView.Pane.data.moved(by: 1), .data)
    }

    @MainActor
    func testSelectionIsRetainedUntilExplicitlyChanged() {
        let navigation = SettingsNavigation(pane: .calendar)
        XCTAssertEqual(navigation.pane, .calendar)
        navigation.pane = .data
        XCTAssertEqual(navigation.pane, .data)
    }

    @MainActor
    func testShellMetricsAndVersionUseSharedValues() {
        XCTAssertEqual(SettingsMetrics.sidebarWidth, 208)
        XCTAssertEqual(SettingsMetrics.windowSize, CGSize(width: 760, height: 600))
        XCTAssertEqual(SettingsMetrics.rowHeight, DesignTokens.Size.buttonHeight.value)
        XCTAssertEqual(SettingsMetrics.dividerHeight, DesignTokens.Size.cardEdge.value)
        XCTAssertEqual(SettingsWindow.versionLabel(version: "1.2"), "Perch 1.2")
        XCTAssertEqual(SettingsWindow.versionLabel(version: "2.3.4 (82)"), "Perch 2.3.4 (82)")
    }

    @MainActor
    func testSectionBuilderKeepsConditionalRowsInOrder() {
        @SettingsSectionBuilder func rows() -> [AnyView] {
            Text("First")
            if true { Text("Second") }
            for index in 0..<3 { Text("\(index)") }
        }
        XCTAssertEqual(rows().count, 5)
    }

    @MainActor
    func testRowGrowsForLongHelpAtNarrowWidth() async {
        _ = NSApplication.shared
        let short = NSHostingView(
            rootView: SettingsRow("Label", help: "Short help.") { Text("Value") }.frame(width: 220))
        let long = NSHostingView(
            rootView: SettingsRow("Label", help: String(repeating: "Readable help. ", count: 30)) { Text("Value") }
                .frame(width: 220))
        short.frame.size.width = 220
        long.frame.size.width = 220
        short.layoutSubtreeIfNeeded()
        long.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(long.fittingSize.height, short.fittingSize.height)
        XCTAssertGreaterThanOrEqual(short.fittingSize.height, SettingsMetrics.rowHeight)
    }
}
