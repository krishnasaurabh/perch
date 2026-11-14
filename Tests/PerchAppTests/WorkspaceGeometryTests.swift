import AppKit
import PerchUI
import XCTest
@testable import PerchApp

final class WorkspaceGeometryTests: XCTestCase {
    @MainActor func testRealGeometryKeepsOneWindowForBothPageWidths() async {
        let screen = NotchLayout.Screen(
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 966),
            safeAreaTop: 34, auxiliaryLeftWidth: 705, auxiliaryRightWidth: 705)
        let base = NotchGeometry(screen: screen)
        let today = base.forWorkspace(.home), week = base.forWorkspace(.week)
        XCTAssertEqual(today.workspace.width, 960)
        XCTAssertEqual(week.workspace.width, 1280)
        XCTAssertEqual(today.window, week.window)
        XCTAssertEqual(today.workspace.maxY, week.workspace.maxY)
        XCTAssertEqual(today.workspace.height, 544)
        XCTAssertTrue(today.window.contains(week.workspace))
        let hiddenMenu = NotchLayout.Screen(
            frame: screen.frame, visibleFrame: screen.frame,
            safeAreaTop: 34, auxiliaryLeftWidth: 705, auxiliaryRightWidth: 705)
        let hidden = NotchGeometry(screen: hiddenMenu).forWorkspace(.home)
        XCTAssertEqual(hidden.workspacePresentation?.menuBarHeight, NSStatusBar.system.thickness)
        XCTAssertGreaterThan(hidden.workspace.height, WorkspaceLayout.sheetHeight)
    }
}
