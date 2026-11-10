import XCTest
@testable import PlannerCore

final class WorkspaceLayoutTests: XCTestCase {
    func testCompactBudgetKeepsThreeHundredPointsBelowTheHeader() {
        for notch: CGFloat in [0, 22, 24, 30, 32, 37.5, 38, 40] {
            let size = WorkspaceLayout.preferredSize(notchHeight: notch)
            XCTAssertEqual(size.width, 820)
            XCTAssertEqual(
                size.height - WorkspaceLayout.headerHeight(notchHeight: notch)
                    - WorkspaceLayout.headerGap - WorkspaceLayout.bottomInset, 300)
            XCTAssertLessThanOrEqual(size.height, 361)
        }
    }

    func testCompactFramesAndRoutingAcrossAllDisplays() {
        for (name, screen) in Screens.all {
            let frame = WorkspaceLayout.frame(screen: screen)
            let size = WorkspaceLayout.preferredSize(notchHeight: NotchLayout.notch(screen: screen).height)
            XCTAssertEqual(frame.width, min(820, screen.frame.width - 16), name)
            XCTAssertEqual(frame.height, size.height, name)
            XCTAssertTrue(screen.frame.contains(frame), name)
            XCTAssertEqual(frame.maxY, screen.frame.maxY - NotchLayout.workspaceTopInset(screen: screen), name)
            let idle = NotchLayout.idleFrame(screen: screen, leftWing: 85, rightWing: 85)
            XCTAssertEqual(NotchLayout.hoverFrame(idle: idle, workspace: frame, expanded: true, screen: screen), frame)
            XCTAssertTrue(NotchLayout.windowFrame(screen: screen, containing: [idle, frame]).contains(frame))
            if !NotchLayout.workspaceAttached(screen: screen) {
                XCTAssertLessThanOrEqual(frame.maxY, screen.frame.maxY - max(screen.menuBarHeight, 24) - 8, name)
            }
        }
    }

    func testVerySmallDisplayClampsRatherThanExtendingOffscreen() {
        let screen = NotchLayout.Screen(
            frame: CGRect(x: -400, y: 50, width: 700, height: 280),
            visibleFrame: CGRect(x: -400, y: 50, width: 700, height: 256))
        let frame = WorkspaceLayout.frame(screen: screen)
        XCTAssertEqual(frame.size, CGSize(width: 684, height: 240))
        XCTAssertEqual(frame.minY, screen.frame.minY + 8)
        XCTAssertEqual(frame.maxY, screen.visibleFrame.maxY - 8)
    }
}
