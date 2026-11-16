#if os(macOS)
    import Foundation
    import PlannerCore
    import XCTest
    @testable import PerchApp

    final class TimeCardTests: XCTestCase {
        private let now = PlannerPreviewScenarios.referenceDate

        func testScheduledBlockUsesStartTimeNotReminderAndSkipsDoneTasks() throws {
            var fixture = try PlannerPreviewScenarios.make("today-before")
            let task = try XCTUnwrap(fixture.planner.tasks.first { $0.title == "Draft the test checklist" })
            fixture.planner.tasks.removeAll { $0.id != task.id }
            fixture.planner.tasks[0].startAt = now.addingTimeInterval(600)
            fixture.planner.tasks[0].remindAt = now.addingTimeInterval(60)
            var presentation = TimeCardPresentation(planner: fixture.planner, day: fixture.day, now: now)
            XCTAssertEqual(presentation.state, .ready)
            XCTAssertEqual(presentation.task?.id, task.id)
            XCTAssertEqual(presentation.start, now.addingTimeInterval(600))
            XCTAssertEqual(presentation.minutes, 45)
            fixture.planner.tasks[0].done = true
            presentation = TimeCardPresentation(planner: fixture.planner, day: fixture.day, now: now)
            XCTAssertEqual(presentation.state, .empty)
        }

        func testUnscheduledTasksAndFinishedFocusDoNotInventBlocks() throws {
            var fixture = try PlannerPreviewScenarios.make("today-running")
            fixture.planner.focus?.state = .finished
            for index in fixture.planner.tasks.indices { fixture.planner.tasks[index].startAt = nil }
            let presentation = TimeCardPresentation(planner: fixture.planner, day: fixture.day, now: now)
            XCTAssertEqual(presentation.state, .empty)
            XCTAssertEqual(presentation.minutes, 25)
        }

        func testRunningRingEmptiesAndHasTimeLeftAccessibility() throws {
            let fixture = try PlannerPreviewScenarios.make("today-running")
            let presentation = TimeCardPresentation(planner: fixture.planner, day: fixture.day, now: now)
            XCTAssertEqual(presentation.state, .running)
            XCTAssertEqual(presentation.digits, "24:10")
            XCTAssertEqual(presentation.fraction, 1450.0 / 2700, accuracy: 0.0001)
            XCTAssertEqual(presentation.ringLabel, "24 minutes 10 seconds left of 45")
            XCTAssertEqual(presentation.completedSteps, 2)
            XCTAssertEqual(presentation.totalSteps, 4)
            XCTAssertEqual(presentation.primaryTitle, "Pause")
            let later = TimeCardPresentation(
                planner: fixture.planner, day: fixture.day, now: now.addingTimeInterval(60))
            XCTAssertLessThan(later.fraction, presentation.fraction)
        }

        func testPauseFreezesTimeAndExtensionKeepsElapsedTime() throws {
            var fixture = try PlannerPreviewScenarios.make("today-running")
            fixture.planner.focus?.pause(at: now)
            let paused = TimeCardPresentation(
                planner: fixture.planner, day: fixture.day, now: now.addingTimeInterval(600))
            XCTAssertEqual(paused.state, .paused)
            XCTAssertEqual(paused.digits, "24:10")
            XCTAssertEqual(paused.primaryTitle, "Continue")
            fixture.planner.focus?.extend(by: 300)
            let extended = TimeCardPresentation(planner: fixture.planner, day: fixture.day, now: now)
            XCTAssertEqual(extended.digits, "29:10")
            XCTAssertEqual(extended.minutes, 50)
            XCTAssertGreaterThan(extended.fraction, paused.fraction)
        }

        func testStopwatchRemainsSupportedWithoutPretendingItHasALimit() throws {
            var fixture = try PlannerPreviewScenarios.make("today-running")
            fixture.planner.focus?.limit = nil
            let presentation = TimeCardPresentation(planner: fixture.planner, day: fixture.day, now: now)
            XCTAssertEqual(presentation.digits, "20:50")
            XCTAssertFalse(presentation.canExtend)
            XCTAssertTrue(presentation.ringLabel.contains("elapsed"))
        }

        func testOnlyFutureBlocksOnTodayAreCandidates() throws {
            var fixture = try PlannerPreviewScenarios.make("today-before")
            for index in fixture.planner.tasks.indices {
                fixture.planner.tasks[index].startAt = now.addingTimeInterval(-60)
            }
            XCTAssertEqual(TimeCardPresentation(planner: fixture.planner, day: fixture.day, now: now).state, .empty)
        }
    }
#endif
