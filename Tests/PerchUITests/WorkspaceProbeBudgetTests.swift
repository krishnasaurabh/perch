import XCTest
@testable import PerchUI

final class WorkspaceProbeBudgetTests: XCTestCase {
    func testTodayProbeBudgetUsesTheMenuBarRatherThanCameraHeight() {
        for menuBar: CGFloat in [24, 32, 34, 37.5] {
            let screen = NotchLayout.Screen(
                frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000 - menuBar),
                safeAreaTop: 38, auxiliaryLeftWidth: 700, auxiliaryRightWidth: 700)
            let budget = WorkspaceLayout.preferredSize(page: .today, menuBarHeight: screen.menuBarHeight)
            let actual = WorkspaceLayout.frame(screen: screen, page: .today)
            XCTAssertEqual(actual.size, budget)
            XCTAssertEqual(actual.width, 960)
            XCTAssertEqual(actual.height, 510 + menuBar)
            XCTAssertNotEqual(actual.height, WorkspaceLayout.preferredSize(notchHeight: 38).height)
        }
    }

    func testAutoHiddenMenuBarUsesTheResolvedPresentationBudget() {
        let screen = NotchLayout.Screen(
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        let presentationMenuBar: CGFloat = 24
        let actual = WorkspaceLayout.frame(screen: screen, page: .today, menuBarHeight: presentationMenuBar)
        let budget = WorkspaceLayout.preferredSize(page: .today, menuBarHeight: presentationMenuBar)
        XCTAssertEqual(actual.size, budget)
        XCTAssertNotEqual(actual.height, WorkspaceLayout.preferredSize(page: .today, menuBarHeight: 0).height)
    }
}
