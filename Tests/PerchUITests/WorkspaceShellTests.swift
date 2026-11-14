import XCTest
@testable import PlannerCore
@testable import PerchUI

final class WorkspaceShellTests: XCTestCase {
    func testBandUsesRuntimeMenuBarAndPagesUseAuthoredWidths() {
        for height: CGFloat in [0, 24, 32, 34, 37.5] {
            XCTAssertEqual(WorkspaceLayout.bandHeight(menuBarHeight: height), height)
            XCTAssertEqual(WorkspaceLayout.preferredSize(page: .today, menuBarHeight: height).width, 960)
            XCTAssertEqual(WorkspaceLayout.preferredSize(page: .week, menuBarHeight: height).width, 1280)
            XCTAssertEqual(WorkspaceLayout.preferredSize(page: .today, menuBarHeight: height).height, 510 + height)
        }
        XCTAssertEqual(WorkspacePage.allCases, [.today, .week])
        XCTAssertEqual(WorkspaceLayout.widthMotion(reduceMotion: false).duration, 0.3)
        XCTAssertTrue(WorkspaceLayout.widthMotion(reduceMotion: false).allowsSpatialMotion)
        XCTAssertEqual(WorkspaceLayout.widthMotion(reduceMotion: true).duration, 0.12)
        XCTAssertFalse(WorkspaceLayout.widthMotion(reduceMotion: true).allowsSpatialMotion)
    }

    func testFramesKeepScreenMarginsAndTopAnchorAcrossPageChanges() {
        for screen in Screens.all.map(\.1) {
            let today = WorkspaceLayout.frame(screen: screen, page: .today)
            let week = WorkspaceLayout.frame(screen: screen, page: .week)
            XCTAssertTrue(screen.frame.contains(today))
            XCTAssertTrue(screen.frame.contains(week))
            XCTAssertLessThanOrEqual(week.width, screen.frame.width - 64)
            XCTAssertEqual(today.maxY, week.maxY)
            XCTAssertEqual(today.midX, week.midX)
            XCTAssertEqual(week.height, today.height)
        }
        let tiny = NotchLayout.Screen(
            frame: CGRect(x: -400, y: 50, width: 700, height: 280),
            visibleFrame: CGRect(x: -400, y: 50, width: 700, height: 256))
        XCTAssertTrue(tiny.frame.contains(WorkspaceLayout.frame(screen: tiny, page: .week)))
    }

    func testThreeColumnsUseConstantRatiosAndDoNotDependOnCardState() {
        for width: CGFloat in [700, 960, 1280] {
            let columns = HomeLayout.columns(sheetWidth: width)
            XCTAssertEqual(columns.checklist / columns.time, 1.55 / 0.9, accuracy: 0.0001)
            XCTAssertEqual(columns.day / columns.time, 1.1 / 0.9, accuracy: 0.0001)
            XCTAssertEqual(columns.checklist + columns.time + columns.day + 4 * 14, width, accuracy: 0.0001)
        }
        XCTAssertEqual(HomeLayout.columns(sheetWidth: 0).checklist, 0)
    }

    func testNarrowWeekDropsOnlyEarliestPastDaysAndKeepsFutureDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let today = DayKey("2026-11-13")
        let days = WeekColumnLayout.days(today: today, calendar: calendar)
        let wide = WorkspaceLayout.weekColumns(days: days, today: today, available: 1252)
        let narrow = WorkspaceLayout.weekColumns(days: days, today: today, available: 896)
        XCTAssertEqual(wide.days, days)
        XCTAssertGreaterThan(narrow.omittedPastDays, 0)
        XCTAssertEqual(narrow.days, Array(days.dropFirst(narrow.omittedPastDays)))
        XCTAssertTrue(days.filter { $0 >= today }.allSatisfy { narrow.days.contains($0) })
        XCTAssertGreaterThanOrEqual(narrow.standardWidth, 140)
        XCTAssertEqual(narrow.width(for: today), narrow.standardWidth * 1.7)
        XCTAssertEqual(narrow.parkingWidth, narrow.standardWidth)
        let tiny = WorkspaceLayout.weekColumns(days: days, today: today, available: 100)
        XCTAssertEqual(tiny.days, days.filter { $0 >= today })
        XCTAssertTrue(tiny.needsHorizontalScroll)
        let past = days.map { $0.adding(days: -7, calendar: calendar) }
        XCTAssertEqual(WorkspaceLayout.weekColumns(days: past, today: today, available: 300).days.count, 1)
    }

    @MainActor
    func testSharedSelectionEditingAndDraftAreTransientAndIndependent() {
        let state = TodayHomeState()
        let selected = UUID(), editing = UUID()
        state.selectedTaskID = selected
        state.editingTaskID = editing
        state.captureDraft = .init(startTime: Date(timeIntervalSince1970: 100), minutes: 25)
        XCTAssertEqual(state.selectedTaskID, selected)
        XCTAssertEqual(state.editingTaskID, editing)
        XCTAssertEqual(state.captureDraft?.minutes, 25)
        XCTAssertEqual(state.captureDraft?.endTime, Date(timeIntervalSince1970: 1600))
        state.captureDraft = nil
        XCTAssertEqual(state.selectedTaskID, selected)
        XCTAssertEqual(state.editingTaskID, editing)
    }
}
