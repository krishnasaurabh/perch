import Foundation
import PerchUI
import SwiftUI
import XCTest
@testable import PerchApp

final class ChecklistStepScrollTests: XCTestCase {
    func testArrowSelectionRequestsCenteredScrollBeyondViewport() throws {
        let ids = (0..<15).map { _ in UUID() }
        let rowHeight = DesignTokens.Size.stepRowHeight.value
        let viewportHeight = 300.0
        XCTAssertGreaterThan(Double(ids.count) * rowHeight, viewportHeight)
        var selected = ids[0]
        var requests: [(UUID, UnitPoint)] = []
        let record: (UUID, UnitPoint) -> Void = { requests.append(($0, $1)) }
        ChecklistStepScroll.reveal(selected, using: record)
        for index in 1..<ids.count {
            selected = try XCTUnwrap(TodayTaskNavigation.neighbor(in: ids, from: selected, offset: 1))
            ChecklistStepScroll.reveal(selected, using: record)
            XCTAssertEqual(requests.last?.0, ids[index])
            XCTAssertEqual(requests.last?.1, .center)
        }
        // The last selected row starts below the capped, initially visible window.
        XCTAssertGreaterThan(Double(ids.count - 1) * rowHeight, viewportHeight)
        XCTAssertEqual(requests.count, ids.count)
        XCTAssertEqual(requests.map(\.0), ids)
        selected = try XCTUnwrap(TodayTaskNavigation.neighbor(in: ids, from: selected, offset: -1))
        ChecklistStepScroll.reveal(selected, using: record)
        XCTAssertEqual(requests.last?.0, ids[13])
        XCTAssertEqual(requests.last?.1, .center)
        ChecklistStepScroll.reveal(nil, using: record)
        XCTAssertEqual(requests.count, ids.count + 1, "Leaving the step cursor must not scroll")
    }
}
