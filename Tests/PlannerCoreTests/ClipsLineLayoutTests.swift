import XCTest
@testable import PlannerCore

final class ClipsLineLayoutTests: XCTestCase {
    func testCurveAndRoundCapsStayInsideContainer() throws {
        for width in [14.0, 120, 320, 480, 740, 1024] {
            let rope = try XCTUnwrap(ClipsLineLayout.rope(width: width))
            for step in 0...100 {
                let point = rope.point(at: Double(step) / 100)
                XCTAssertGreaterThanOrEqual(point.x - 0.75, 0)
                XCTAssertLessThanOrEqual(point.x + 0.75, width)
                XCTAssertGreaterThanOrEqual(point.y - 0.75, 0)
                XCTAssertLessThanOrEqual(point.y + 0.75, ClipsLineLayout.bandHeight)
            }
            XCTAssertEqual(rope.point(at: 0.5).x, width / 2, accuracy: 0.001)
            XCTAssertEqual(rope.point(at: 0.5).y, ClipsLineLayout.emptyMessageTop, accuracy: 0.001)
            XCTAssertEqual(rope.start.x, width - rope.end.x, accuracy: 0.001)
        }
    }

    func testUnlaidOutOrInvalidWidthDrawsNoRope() {
        for width in [-1.0, 0, 12, 13, .infinity, .nan] {
            XCTAssertNil(ClipsLineLayout.rope(width: width))
        }
    }

    func testHintsOnlyHaveMeaningWithClips() {
        XCTAssertFalse(ClipsLineLayout.showsGestureHints(clipCount: 0))
        XCTAssertTrue(ClipsLineLayout.showsGestureHints(clipCount: 1))
        XCTAssertTrue(ClipsLineLayout.showsGestureHints(clipCount: 12))
    }
}
