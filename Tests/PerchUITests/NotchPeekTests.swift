import Foundation
import PlannerCore
import PerchUI
import XCTest

final class NotchPeekTests: XCTestCase {
    func testHoverLevelsAreIndependentOfClickAndPillsAlwaysPeek() {
        XCTAssertEqual(NotchOpenLevel.hover(.hover), .peek)
        XCTAssertEqual(NotchOpenLevel.hover(.everything), .everything)
        for trigger in [NotchOpenTrigger.nothing, .click, .doubleClick] {
            XCTAssertEqual(NotchOpenLevel.hover(trigger), .closed)
            XCTAssertEqual(NotchOpenLevel.hover(trigger, pill: true), .peek)
        }
        XCTAssertEqual(NotchOpenLevel.hover(.everything, pill: true), .peek)
        XCTAssertEqual(NotchHoverIntent.delay, 0.25)
    }

    func testCurrentTaskWinsAndOnlyItsNextUnfinishedStepAppears() throws {
        let fixture = try PlannerPreviewScenarios.make("notch-running")
        let peek = NotchPeekPresentation(planner: fixture.planner, today: fixture.day)
        XCTAssertEqual(peek.task?.id, fixture.planner.focus?.taskID)
        XCTAssertEqual(peek.nextStep?.title, "Write the smoke tests")
        XCTAssertEqual(peek.moreToday, 4)
        XCTAssertEqual(peek.focus?.state, .running)
        var planner = fixture.planner
        planner.tasks[0].steps[2].done = true
        XCTAssertEqual(NotchPeekPresentation(planner: planner, today: fixture.day).nextStep?.title, "Share it with Sam")
    }

    func testIdlePausedFinishedAndEmptyStates() throws {
        var fixture = try PlannerPreviewScenarios.make("notch-paused")
        XCTAssertEqual(NotchPeekPresentation(planner: fixture.planner, today: fixture.day).focus?.state, .paused)
        fixture.planner.focus?.state = .finished
        let next = NotchPeekPresentation(planner: fixture.planner, today: fixture.day)
        XCTAssertNil(next.focus)
        XCTAssertEqual(next.task?.id, fixture.planner.tasks.first { !$0.done && $0.day == fixture.day }?.id)
        XCTAssertNil(NotchPeekPresentation(planner: Planner(), today: fixture.day).task)
        fixture.planner.tasks.removeAll()
        fixture.planner.focus?.state = .running
        XCTAssertNil(NotchPeekPresentation(planner: fixture.planner, today: fixture.day).task)
    }

    func testCaptureUsesSlashOrCommandReturnWithoutSavingBlankThoughts() {
        XCTAssertEqual(NotchPeekCapture("  Buy stamps  "), .task("Buy stamps"))
        XCTAssertEqual(NotchPeekCapture(" / A thought "), .thought("A thought"))
        XCTAssertEqual(NotchPeekCapture("A thought", park: true), .thought("A thought"))
        XCTAssertEqual(NotchPeekCapture("/ A thought", park: true), .thought("A thought"))
        XCTAssertNil(NotchPeekCapture(" / "))
        XCTAssertNil(NotchPeekCapture(" \n ", park: true))
    }

    func testPeekFrameKeepsWorkspaceTopAndFitsOnOffsetDisplays() {
        for origin in [CGPoint.zero, CGPoint(x: -1800, y: 400)] {
            let workspace = CGRect(origin: origin, size: CGSize(width: 960, height: 540))
            let rect = NotchPeekLayout.frame(workspace: workspace, bandHeight: 34)
            XCTAssertEqual(rect.width, 460)
            XCTAssertEqual(rect.midX, workspace.midX)
            XCTAssertEqual(rect.maxY, workspace.maxY)
            XCTAssertTrue(workspace.contains(rect))
        }
    }
}
