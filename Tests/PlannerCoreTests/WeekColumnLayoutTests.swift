import XCTest
@testable import PlannerCore

final class WeekColumnLayoutTests: XCTestCase {
    func testChipHelpLeadsWithTheFullTitleThenTheDragHint() {
        let title = "Draft the quarterly planning document for the platform team including hiring and budget sections"
        XCTAssertEqual(WeekColumnLayout.chipHelp(title: title, past: false),
                       title + "\nDrag to move. Double-click for details.")
    }

    func testPastChipHelpKeepsTheTitleWithTheReadOnlyHint() {
        XCTAssertEqual(WeekColumnLayout.chipHelp(title: "Call mom", past: true), "Call mom\nOlder days stay unchanged in your history.")
    }

    func testBlankTitleFallsBackToTheHintAlone() {
        XCTAssertEqual(WeekColumnLayout.chipHelp(title: "  ", past: false), WeekColumnLayout.dragHint)
    }

    func testChipsBelowTheViewportCountAsHidden() {
        // Ten chips of 30 pt with 4 pt gaps in a 200 pt column: six end inside, four below.
        let bottoms = (0..<10).map { Double($0) * 34 + 30 }
        XCTAssertEqual(WeekColumnLayout.hiddenBelow(chipBottoms: bottoms, viewport: 200), 4)
        XCTAssertEqual(WeekColumnLayout.overflowLabel(hidden: 4), "+4 more")
    }

    func testScrolledToTheEndHidesNothingBelow() {
        // Scrolling moves bottoms up; chips above the top are not "more below".
        let bottoms = (0..<10).map { Double($0) * 34 + 30 - 140 }
        XCTAssertEqual(WeekColumnLayout.hiddenBelow(chipBottoms: bottoms, viewport: 200), 0)
        XCTAssertNil(WeekColumnLayout.overflowLabel(hidden: 0))
    }

    func testNoLayoutYetMeansNothingHidden() {
        XCTAssertEqual(WeekColumnLayout.hiddenBelow(chipBottoms: [40, 80], viewport: 0), 0)
    }

    func testAChipFlushWithTheBottomEdgeIsVisible() {
        XCTAssertEqual(WeekColumnLayout.hiddenBelow(chipBottoms: [200, 200.4], viewport: 200), 0)
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
