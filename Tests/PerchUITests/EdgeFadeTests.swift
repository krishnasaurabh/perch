import XCTest
@testable import PlannerCore
@testable import PerchUI

final class EdgeFadeTests: XCTestCase {
    func testTextThatFitsHasNoFade() {
        XCTAssertFalse(EdgeFade.showsBottomFade(contentHeight: 60, visibleOffset: 0, visibleHeight: 160))
    }

    func testTextExactlyFillingTheAreaHasNoFade() {
        XCTAssertFalse(EdgeFade.showsBottomFade(contentHeight: 160, visibleOffset: 0, visibleHeight: 160))
        // Sub-point layout rounding is not overflow.
        XCTAssertFalse(EdgeFade.showsBottomFade(contentHeight: 160.4, visibleOffset: 0, visibleHeight: 160))
    }

    func testOverflowingTextFades() {
        XCTAssertTrue(EdgeFade.showsBottomFade(contentHeight: 420, visibleOffset: 0, visibleHeight: 160))
        XCTAssertTrue(EdgeFade.showsBottomFade(contentHeight: 161, visibleOffset: 0, visibleHeight: 160))
    }

    func testScrolledToTheEndHasNoFade() {
        XCTAssertTrue(EdgeFade.showsBottomFade(contentHeight: 420, visibleOffset: 200, visibleHeight: 160))
        XCTAssertFalse(EdgeFade.showsBottomFade(contentHeight: 420, visibleOffset: 260, visibleHeight: 160))
    }

    func testCollapsedAreaHasNoFade() {
        XCTAssertFalse(EdgeFade.showsBottomFade(contentHeight: 420, visibleOffset: 0, visibleHeight: 0))
    }
}
