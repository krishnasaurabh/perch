#if os(macOS)
    import Foundation
    import PlannerCore
    import XCTest
    @testable import PerchApp

    final class TimeCardRefreshAndStepsTests: XCTestCase {
        func testIdleScheduleKeepsUpdatingAcrossBlockBoundariesWithoutPlannerChanges() throws {
            let fixture = try PlannerPreviewScenarios.make("today-before")
            let planner = fixture.planner
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(planner)
            let interval = try XCTUnwrap(TimeCardPresentation.refreshInterval(planner: planner, day: fixture.day))
            XCTAssertEqual(interval, 60)
            let before = TimeCardPresentation(planner: planner, day: fixture.day, now: fixture.now)
            let after = TimeCardPresentation(
                planner: planner, day: fixture.day, now: fixture.now.addingTimeInterval(60 * 60))
            XCTAssertEqual(before.task?.title, "Draft the test checklist")
            XCTAssertEqual(after.task?.title, "Review the release notes")
            XCTAssertEqual(after.primaryTitle, "Start it now")
            XCTAssertEqual(TimeCardPresentation.refreshInterval(planner: planner, day: fixture.day), interval)
            XCTAssertEqual(try encoder.encode(planner), encoded)
        }

        func testPausedAndUnscheduledCardsDoNotScheduleDisplayTicks() throws {
            let paused = try PlannerPreviewScenarios.make("today-paused")
            XCTAssertNil(TimeCardPresentation.refreshInterval(planner: paused.planner, day: paused.day))
            var idle = try PlannerPreviewScenarios.make("today-before")
            for index in idle.planner.tasks.indices { idle.planner.tasks[index].startAt = nil }
            XCTAssertNil(TimeCardPresentation.refreshInterval(planner: idle.planner, day: idle.day))
            let empty = try PlannerPreviewScenarios.make("today-empty")
            XCTAssertNil(TimeCardPresentation.refreshInterval(planner: empty.planner, day: empty.day))
        }

        func testRunningCardUsesSecondUpdates() throws {
            let fixture = try PlannerPreviewScenarios.make("today-running")
            XCTAssertEqual(TimeCardPresentation.refreshInterval(planner: fixture.planner, day: fixture.day), 1)
        }

        func testFourStepsKeepOnePipPerStep() {
            let progress = TimeCardStepProgress(completed: 2, total: 4)
            XCTAssertEqual(progress.fractions, [1, 1, 0, 0])
            XCTAssertFalse(progress.stacked)
        }

        func testManyStepRunningAndPausedCardsKeepCompleteCountsAndBoundedPips() throws {
            for name in ["today-running", "today-paused"] {
                var fixture = try PlannerPreviewScenarios.make(name)
                let index = try XCTUnwrap(fixture.planner.tasks.firstIndex { $0.id == fixture.planner.focus?.taskID })
                fixture.planner.tasks[index].steps = (0..<20).map {
                    Subtask(title: "Checklist item \($0 + 1)", done: $0 < 7)
                }
                let value = TimeCardPresentation(planner: fixture.planner, day: fixture.day, now: fixture.now)
                let progress = TimeCardStepProgress(completed: value.completedSteps, total: value.totalSteps)
                XCTAssertEqual(value.totalSteps, 20)
                XCTAssertEqual(value.completedSteps, 7)
                XCTAssertTrue(progress.stacked)
                XCTAssertEqual(progress.fractions.count, 4)
                XCTAssertEqual(progress.fractions[0], 1)
                XCTAssertEqual(progress.fractions[1], 0.4, accuracy: 0.0001)
                XCTAssertEqual(progress.fractions[2], 0)
                XCTAssertEqual(progress.fractions[3], 0)
            }
        }

        func testPipWorkIsBoundedAndProgressIsClamped() {
            XCTAssertEqual(TimeCardStepProgress(completed: 0, total: 0).fractions, [])
            XCTAssertEqual(TimeCardStepProgress(completed: -1, total: 20).fractions, [0, 0, 0, 0])
            XCTAssertEqual(TimeCardStepProgress(completed: 25, total: 20).fractions, [1, 1, 1, 1])
            XCTAssertEqual(TimeCardStepProgress(completed: 0, total: Int.max).fractions.count, 4)
        }
    }
#endif
