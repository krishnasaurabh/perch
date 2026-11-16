import Foundation
import PlannerCore
import PerchUI
import XCTest

final class NotchActiveBlockTests: XCTestCase {
    private let now = PlannerPreviewScenarios.referenceDate
    private let locale = Locale(identifier: "en_US_POSIX")

    func testTasklessBlocksNeverBorrowAnotherTasksTitleOrSteps() throws {
        for stopwatch in [false, true] {
            for paused in [false, true] {
                for hasOtherTask in [false, true] {
                    let day = PlannerEngine(planner: Planner(), now: { self.now }).today
                    var planner = Planner()
                    if hasOtherTask {
                        var task = PlanTask(title: "Unrelated task", day: day, createdAt: now)
                        task.steps = [Subtask(title: "Unrelated step")]
                        planner.tasks = [task]
                    }
                    var engine = PlannerEngine(planner: planner, now: { self.now })
                    if stopwatch {
                        _ = try engine.startStopwatch(taskID: nil)
                    } else {
                        _ = try engine.startTimer(task: nil, minutes: 25)
                    }
                    if paused { try engine.pauseTimer() }
                    let peek = NotchPeekPresentation(planner: engine.planner, today: engine.today)
                    XCTAssertNil(peek.task)
                    XCTAssertNil(peek.nextStep)
                    XCTAssertTrue(peek.showsBlock)
                    XCTAssertEqual(peek.title, "Time set aside")
                    XCTAssertEqual(peek.focus, engine.planner.focus)
                    XCTAssertEqual(peek.focus?.state, paused ? .paused : .running)
                    XCTAssertEqual(peek.moreToday, hasOtherTask ? 1 : 0)
                }
            }
        }
    }

    func testStandaloneBlockSnapshotFixturesKeepTheirClockAndChecklistState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        for name in ["notch-running", "notch-paused"] {
            let source = try PlannerPreviewScenarios.make(name)
            for stopwatch in [false, true] {
                for empty in [false, true] {
                    let fixture = try PlannerPreviewScenarios.installTasklessBlock(
                        source, in: file, stopwatch: stopwatch, empty: empty)
                    let saved = try file.load()
                    XCTAssertEqual(saved.focus, fixture.planner.focus)
                    XCTAssertNil(saved.focus?.taskID)
                    XCTAssertEqual(saved.focus?.state, source.planner.focus?.state)
                    XCTAssertEqual(saved.focus?.limit, stopwatch ? nil : 1500)
                    XCTAssertEqual(saved.focus?.elapsed(at: fixture.now), 75)
                    XCTAssertEqual(saved.tasks, empty ? [] : source.planner.tasks)
                }
            }
        }
    }

    func testEmptyWithoutAnActiveBlockStillShowsTheEmptyState() {
        let peek = NotchPeekPresentation(planner: Planner(), today: DayKey("2026-11-13"))
        XCTAssertFalse(peek.showsBlock)
        XCTAssertNil(peek.focus)
        XCTAssertNil(peek.task)
    }

    func testMissingOrFinishedLinkedTaskDoesNotBorrowNextTask() {
        let day = DayKey("2026-11-13")
        var planner = Planner()
        let other = PlanTask(title: "Next task", day: day, createdAt: now)
        var linked = PlanTask(title: "Finished task", day: day, done: true, createdAt: now)
        linked.steps = [Subtask(title: "Old step")]
        for linkedTasks in [[], [linked]] {
            planner.tasks = [other] + linkedTasks
            planner.focus = FocusSession(taskID: linked.id, limit: 1500, now: now)
            let peek = NotchPeekPresentation(planner: planner, today: day)
            XCTAssertNil(peek.task)
            XCTAssertNil(peek.nextStep)
            XCTAssertNotNil(peek.focus)
            XCTAssertEqual(peek.moreToday, 1)
        }
        planner.focus?.state = .finished
        XCTAssertEqual(NotchPeekPresentation(planner: planner, today: day).task?.id, other.id)
    }

    func testTimePillDistinguishesElapsedFromRemainingWhileRunningAndPaused() throws {
        let day = DayKey("2026-11-13")
        for stopwatch in [false, true] {
            for paused in [false, true] {
                var planner = Planner()
                planner.preferences.notchTimePill = true
                planner.preferences.hideCountsAndTimes = false
                var focus = FocusSession(taskID: nil, limit: stopwatch ? nil : 1500, now: now)
                focus.banked = 75
                if paused { focus.state = .paused; focus.resumedAt = nil }
                planner.focus = focus
                let face = try XCTUnwrap(
                    NotchPillPresentation.make(planner: planner, today: day, now: now, locale: locale).first)
                let state = paused ? "Paused" : "Time set aside"
                let value = stopwatch ? "01:15 elapsed" : "23:45 left"
                XCTAssertEqual(face.accessibilityLabel, "\(state), \(value)")
                XCTAssertEqual(face.help, "\(state), \(value)")
                XCTAssertEqual(face.text, stopwatch ? "01:15" : "23:45")
                XCTAssertEqual(face.showsDot, !paused)
                let time = NotchBlockTimePresentation(focus: focus, now: now, locale: locale)
                XCTAssertEqual(time.valueDescription, value)
                XCTAssertEqual(time.accessibilityLabel, face.accessibilityLabel)
                let pseudo = NotchBlockTimePresentation(focus: focus, now: now, locale: Locale(identifier: "zz"))
                XCTAssertTrue(pseudo.state.hasPrefix("⟦"))
                XCTAssertTrue(pseudo.valueDescription.hasPrefix("⟦"))
                let flat = NotchFlatTabPresentation(
                    closed: NotchClosedPresentation(planner: planner), hideValues: false, now: now, locale: locale)
                XCTAssertEqual(flat.accessibilityLabel, "\(state), \(value). Open Today")
                let later = NotchBlockTimePresentation(focus: focus, now: now.addingTimeInterval(10), locale: locale)
                XCTAssertEqual(later.face.fullText, paused ? time.face.fullText : stopwatch ? "01:25" : "23:35")
                planner.preferences.hideCountsAndTimes = true
                let hidden = try XCTUnwrap(
                    NotchPillPresentation.make(planner: planner, today: day, now: now, locale: locale).first)
                XCTAssertEqual(hidden.text, "")
                XCTAssertEqual(hidden.accessibilityLabel, state)
                XCTAssertEqual(hidden.help, state)
            }
        }
    }
}
