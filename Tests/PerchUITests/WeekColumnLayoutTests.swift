import XCTest
@testable import PlannerCore
@testable import PerchUI

final class WeekColumnLayoutTests: XCTestCase {
    func testChipHelpLeadsWithTheFullTitleThenTheDragHint() {
        let title = "Draft the quarterly planning document for the platform team including hiring and budget sections"
        XCTAssertEqual(
            WeekColumnLayout.chipHelp(title: title, past: false),
            title + "\nDrag to move. Double-click for details.")
    }

    func testPastChipHelpKeepsTheTitleWithTheReadOnlyHint() {
        XCTAssertEqual(
            WeekColumnLayout.chipHelp(title: "Call mom", past: true),
            "Call mom\nOlder days stay unchanged in your history.")
    }

    func testBlankTitleFallsBackToTheHintAlone() {
        XCTAssertEqual(WeekColumnLayout.chipHelp(title: "  ", past: false), WeekColumnLayout.dragHint)
    }

    private func chips(tops: [Double], height: Double = 30) -> [(top: Double, bottom: Double)] {
        tops.map { (top: $0, bottom: $0 + height) }
    }

    func testChipsBelowTheViewportCountAsHidden() {
        // Ten chips of 30 pt with 4 pt gaps in a 200 pt column: six end inside, four below.
        let column = chips(tops: (0..<10).map { Double($0) * 34 })
        XCTAssertEqual(WeekColumnLayout.hiddenBelow(chips: column, viewport: 200), 4)
        XCTAssertEqual(WeekColumnLayout.overflowLabel(hidden: 4), "+4 more")
    }

    func testScrolledToTheEndHidesNothingBelow() {
        // Scrolling moves chips up; chips above the top are not "more below".
        let column = chips(tops: (0..<10).map { Double($0) * 34 - 140 })
        XCTAssertEqual(WeekColumnLayout.hiddenBelow(chips: column, viewport: 200), 0)
        XCTAssertNil(WeekColumnLayout.overflowLabel(hidden: 0))
    }

    func testNoLayoutYetMeansNothingHidden() {
        XCTAssertEqual(WeekColumnLayout.hiddenBelow(chips: chips(tops: [10, 50]), viewport: 0), 0)
    }

    func testAChipFlushWithTheBottomEdgeIsVisible() {
        XCTAssertEqual(
            WeekColumnLayout.hiddenBelow(chips: [(top: 170, bottom: 200), (top: 170, bottom: 200.4)], viewport: 200), 0)
    }

    func testAChipCutOffByTheFadeIsStillShownNotCountedAsMore() {
        // A busy day: one tall chip runs past the 200 pt viewport, twelve more start below it.
        // The tall chip is on screen, so the label says "+12 more", not "+13 more".
        let column = [(top: 0.0, bottom: 240.0)] + chips(tops: (0..<12).map { 244 + Double($0) * 34 })
        XCTAssertEqual(WeekColumnLayout.hiddenBelow(chips: column, viewport: 200, fade: 22), 12)
    }

    func testAChipThatOnlyStartsInsideTheFadeCountsAsHidden() {
        // Its top sits under the fade, so only a faded sliver shows.
        let column = [(top: 0.0, bottom: 170.0), (top: 185.0, bottom: 215.0)]
        XCTAssertEqual(WeekColumnLayout.hiddenBelow(chips: column, viewport: 200, fade: 22), 1)
        // The same chip starting just above the fade is readable, so it is not counted.
        let readable = [(top: 0.0, bottom: 170.0), (top: 177.0, bottom: 207.0)]
        XCTAssertEqual(WeekColumnLayout.hiddenBelow(chips: readable, viewport: 200, fade: 22), 0)
    }

    func testATitleWhoseWordsFitKeepsTheRegularTwoLines() {
        XCTAssertEqual(WeekColumnLayout.titleFit(widestWord: 40, available: 52), .init(size: 11, lines: 2))
    }

    func testAWordSlightlyTooWideStepsTheTitleDownInHalfPoints() {
        // "Standup" ~44 pt at 11 pt in a 41 pt title: 11 * 41 / 44 = 10.25, so 10 pt.
        let fit = WeekColumnLayout.titleFit(widestWord: 44, available: 41)
        XCTAssertEqual(fit, .init(size: 10, lines: 2))
        XCTAssertLessThanOrEqual(44 * fit.size / WeekColumnLayout.titleSize, 41)
    }

    func testAWordTooWideEvenAtTheSmallestSizeTruncatesOnOneLine() {
        XCTAssertEqual(WeekColumnLayout.titleFit(widestWord: 70, available: 50), .init(size: 11, lines: 1))
    }

    func testTheSmallestSizeIsUsedWhenItIsExactlyEnough() {
        XCTAssertEqual(WeekColumnLayout.titleFit(widestWord: 55, available: 47.5), .init(size: 9.5, lines: 2))
    }

    func testBeforeLayoutTheTitleUsesTheRegularSetting() {
        XCTAssertEqual(WeekColumnLayout.titleFit(widestWord: 90, available: 0), .init(size: 11, lines: 2))
    }
}
