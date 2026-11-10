import PlannerTestSupport
import XCTest
@testable import PlannerCore

/// Focus timer behavior: pause/resume/extend, sleep gaps, DST-spanning sessions,
/// and the engine paths that feed Insights.
final class FocusSessionEdgeTests: XCTestCase {
    private let t0 = Fixture.now
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func makeEngine() -> (PlannerEngine, (Double) -> Void) {
        final class Box { var clock: Date; init(_ d: Date) { clock = d } }
        let box = Box(t0)
        let engine = PlannerEngine(planner: Planner(), now: { box.clock }, calendar: Fixture.calendar)
        return (engine, { box.clock = self.at($0) })
    }

    // MARK: FocusSession value semantics

    func testCountdownAccruesOnlyWhileRunning() {
        var s = FocusSession(taskID: nil, limit: 1500, now: t0)
        XCTAssertEqual(s.elapsed(at: at(10)), 600, accuracy: 0.01)
        XCTAssertEqual(s.remaining(at: at(10))!, 900, accuracy: 0.01)

        let first = s.pause(at: at(10))
        XCTAssertEqual(first?.seconds ?? -1, 600, accuracy: 0.01)
        XCTAssertEqual(s.state, .paused)
        XCTAssertNil(s.resumedAt)

        // A long gap while paused is not counted.
        XCTAssertEqual(s.elapsed(at: at(180)), 600, accuracy: 0.01)

        s.resume(at: at(180))
        XCTAssertEqual(s.elapsed(at: at(185)), 900, accuracy: 0.01)

        let second = s.finish(at: at(185))
        XCTAssertEqual(second?.seconds ?? -1, 300, accuracy: 0.01)
        XCTAssertEqual(s.state, .finished)
        XCTAssertEqual(s.elapsed(at: at(999)), 900, accuracy: 0.01, "a finished session is frozen")
    }

    func testPauseImmediatelyProducesNoSegment() {
        var s = FocusSession(taskID: nil, limit: 1500, now: t0)
        XCTAssertNil(s.pause(at: t0))
        XCTAssertEqual(s.banked, 0)
        XCTAssertEqual(s.state, .paused)
    }

    func testPauseClampsACountdownAtTheLimitAfterSleep() {
        var s = FocusSession(taskID: nil, limit: 1500, now: t0)
        // The machine slept for two hours; the countdown must stop at 25 minutes.
        let seg = s.pause(at: at(120))
        XCTAssertEqual(seg?.seconds ?? -1, 1500, accuracy: 0.01)
        XCTAssertEqual(s.elapsed(at: at(120)), 1500, accuracy: 0.01)
        XCTAssertEqual(s.remaining(at: at(120)), 0)
        XCTAssertTrue(s.isOver(at: at(120)))
    }

    func testResumeAfterTheCountdownAlreadyElapsed() {
        var s = FocusSession(taskID: nil, limit: 1500, now: t0)
        s.pause(at: at(120))  // clamped to 1500
        s.resume(at: at(300))
        XCTAssertTrue(s.isOver(at: at(300)))
        XCTAssertEqual(s.remaining(at: at(300)), 0)
    }

    func testStopwatchCountsWallTimeUntilPaused() {
        var s = FocusSession(taskID: nil, limit: nil, now: t0)
        XCTAssertNil(s.remaining(at: at(60)))
        XCTAssertFalse(s.isOver(at: at(600)))
        let seg = s.pause(at: at(120))
        XCTAssertEqual(seg?.seconds ?? -1, 7200, accuracy: 0.01)
        XCTAssertEqual(s.elapsed(at: at(600)), 7200, accuracy: 0.01)
    }

    func testExtendMovesTheLimit() {
        var s = FocusSession(taskID: nil, limit: 1500, now: t0)
        s.extend(by: 300)
        XCTAssertEqual(s.limit, 1800)
        XCTAssertEqual(s.remaining(at: at(10))!, 1200, accuracy: 0.01)
    }

    func testExtendDoesNothingOnAStopwatch() {
        var s = FocusSession(taskID: nil, limit: nil, now: t0)
        s.extend(by: 300)
        XCTAssertNil(s.limit)
    }

    func testElapsedNeverGoesNegative() {
        let s = FocusSession(taskID: nil, limit: 1500, now: t0)
        XCTAssertEqual(s.elapsed(at: t0.addingTimeInterval(-60)), 0)
        XCTAssertEqual(s.remaining(at: t0.addingTimeInterval(-60))!, 1500)
    }

    func testTimerTextFormatting() {
        XCTAssertEqual(TimerText.clock(0), "00:00")
        XCTAssertEqual(TimerText.clock(59), "00:59")
        XCTAssertEqual(TimerText.clock(59.2), "01:00", "rounds up so a timer never shows 00:00 while running")
        XCTAssertEqual(TimerText.clock(60), "01:00")
        XCTAssertEqual(TimerText.clock(65), "01:05")
        XCTAssertEqual(TimerText.clock(1500), "25:00")
        XCTAssertEqual(TimerText.clock(3600), "1:00:00")
        XCTAssertEqual(TimerText.clock(3661), "1:01:01")

        XCTAssertEqual(TimerText.short(0), "0m")
        XCTAssertEqual(TimerText.short(59), "1m")
        XCTAssertEqual(TimerText.short(1500), "25m")
        XCTAssertEqual(TimerText.short(3600), "1h")
        XCTAssertEqual(TimerText.short(3900), "1h 5m")
        XCTAssertEqual(TimerText.short(7200), "2h")
    }

    // MARK: Engine paths

    func testPauseResumeThroughTheEngineIgnoresSleepGaps() throws {
        let (varEngine, setClock) = makeEngine()
        var engine = varEngine
        _ = try engine.addTasks(["deep work"])
        try engine.startTimer(task: try Fixture.taskID("deep work", in: engine.planner), minutes: 25)

        setClock(10)
        try engine.pauseTimer()
        XCTAssertFalse(engine.tick(), "a paused timer never finishes on a tick")
        XCTAssertEqual(engine.planner.tasks[0].focusedSeconds, 600, accuracy: 0.5)
        XCTAssertEqual(engine.planner.focusSegments.count, 1)
        setClock(180)  // slept for almost three hours while paused
        XCTAssertFalse(engine.tick())
        XCTAssertEqual(engine.planner.tasks[0].focusedSeconds, 600, accuracy: 0.5)
        XCTAssertEqual(engine.insights().today.focusSeconds, 600, accuracy: 0.5)
        try engine.resumeTimer()
        setClock(190)
        XCTAssertFalse(engine.tick())
        // The resumed stretch is checkpointed, not deferred until pause/finish.
        XCTAssertEqual(engine.planner.tasks[0].focusedSeconds, 1200, accuracy: 0.5)
        XCTAssertEqual(engine.planner.focus?.banked, 1200)
        XCTAssertEqual(engine.planner.focus?.resumedAt, at(190))
        XCTAssertEqual(engine.planner.focusSegments.count, 2)
        XCTAssertFalse(engine.tick(), "repeating a checkpoint at the same instant is a no-op")
        XCTAssertEqual(engine.planner.tasks[0].focusedSeconds, 1200, accuracy: 0.5)
        XCTAssertEqual(engine.planner.focusSegments.count, 2)

        setClock(205)
        XCTAssertTrue(engine.tick(), "25 running minutes are up")
        XCTAssertEqual(engine.planner.tasks[0].focusedSeconds, 1500, accuracy: 0.5)
        XCTAssertEqual(engine.insights().today.focusSeconds, 1500, accuracy: 0.5)
        let segments = engine.planner.focusSegments
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.map(\.start), [t0, at(180), at(190)])
        XCTAssertEqual(
            segments.map(\.end), [at(10), at(190), at(195)],
            "exclude the paused gap and cap the final tail at the countdown limit")
        XCTAssertEqual(segments.map(\.seconds), [600, 600, 300])
        XCTAssertTrue(segments.allSatisfy { $0.taskID == engine.planner.tasks[0].id })
        for (previous, next) in zip(segments, segments.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.end, next.start, "checkpoint intervals must not overlap")
        }
        XCTAssertFalse(engine.tick())
        XCTAssertEqual(engine.planner.focusSegments, segments, "finished ticks must not record again")
        XCTAssertEqual(engine.planner.tasks[0].focusedSeconds, 1500, accuracy: 0.5)
    }

    func testTickFinishesExactlyAtTheLimit() throws {
        let (varEngine, setClock) = makeEngine()
        var engine = varEngine
        _ = try engine.addTasks(["a"])
        try engine.startTimer(task: try Fixture.taskID("a", in: engine.planner), minutes: 25)
        setClock(24.983)
        XCTAssertFalse(engine.tick())
        setClock(25)
        XCTAssertTrue(engine.tick())
        XCTAssertEqual(engine.planner.focus?.state, .finished)
        XCTAssertEqual(engine.planner.tasks[0].focusedSeconds, 1500, accuracy: 0.5)
        XCTAssertEqual(engine.insights().today.focusSeconds, 1500, accuracy: 0.5)
    }

    func testTickAfterALongSleepCapsRecordedFocusAtTheLimit() throws {
        let (varEngine, setClock) = makeEngine()
        var engine = varEngine
        _ = try engine.addTasks(["a"])
        try engine.startTimer(task: try Fixture.taskID("a", in: engine.planner), minutes: 25)
        setClock(180)  // woke up three hours later
        XCTAssertTrue(engine.tick())
        XCTAssertEqual(engine.planner.tasks[0].focusedSeconds, 1500, accuracy: 0.5)
        XCTAssertEqual(engine.planner.focusSegments.first?.seconds ?? -1, 1500, accuracy: 0.5)
    }

    func testExtendAfterFinishedReopensForKeepFocusing() throws {
        let (varEngine, setClock) = makeEngine()
        var engine = varEngine
        _ = try engine.addTasks(["a"])
        try engine.startTimer(task: try Fixture.taskID("a", in: engine.planner), minutes: 25)
        setClock(25)
        XCTAssertTrue(engine.tick())
        XCTAssertEqual(engine.planner.focus?.state, .finished)

        try engine.extendTimer(minutes: 5)
        XCTAssertEqual(engine.planner.focus?.state, .paused, "keep focusing puts the clock back in a resumable state")
        XCTAssertEqual(engine.planner.focus?.limit, 1800)

        try engine.resumeTimer()
        setClock(29)
        XCTAssertFalse(engine.tick())
        setClock(30)
        XCTAssertTrue(engine.tick())
        XCTAssertEqual(engine.planner.tasks[0].focusedSeconds, 1800, accuracy: 0.5)
    }

    func testExtendWhileRunningAddsRemainingTime() throws {
        let (varEngine, setClock) = makeEngine()
        var engine = varEngine
        try engine.startTimer(task: nil, minutes: 10)
        setClock(4)
        try engine.extendTimer(minutes: 5)
        XCTAssertEqual(engine.planner.focus!.remaining(at: at(4))!, 660, accuracy: 0.5)
        setClock(14)
        XCTAssertFalse(engine.tick())
        setClock(15)
        XCTAssertTrue(engine.tick())
    }

    func testStartTimerReplacesTheActiveTimerAndRecordsTheOldStretch() throws {
        let (varEngine, setClock) = makeEngine()
        var engine = varEngine
        _ = try engine.addTasks(["a"])
        try engine.startTimer(task: try Fixture.taskID("a", in: engine.planner), minutes: 25)
        setClock(10)
        try engine.startTimer(task: nil, minutes: 10)
        XCTAssertEqual(engine.planner.focusSegments.first?.seconds ?? -1, 600, accuracy: 0.5)
        XCTAssertEqual(engine.planner.tasks[0].focusedSeconds, 600, accuracy: 0.5)
        XCTAssertEqual(engine.planner.focus?.limit, 600)
    }

    func testStartTimerUsesTheTaskLimitThenTheDefault() throws {
        let (varEngine, _) = makeEngine()
        var engine = varEngine
        _ = try engine.addTasks(["a"])
        try engine.startTimer(task: try Fixture.taskID("a", in: engine.planner), minutes: nil)
        XCTAssertEqual(engine.planner.focus?.limit, 1500, "default 25 minutes")

        var edit = TaskEdit(); edit.minutes = 50
        _ = try engine.update(try Fixture.taskID("a", in: engine.planner), on: .day("2026-11-09"), edit)
        try engine.startTimer(task: try Fixture.taskID("a", in: engine.planner), minutes: nil)
        XCTAssertEqual(engine.planner.focus?.limit, 3000)

        try engine.startTimer(task: nil, minutes: 5)
        XCTAssertEqual(engine.planner.focus?.limit, 300)

        try engine.startTimer(task: nil, minutes: nil)
        XCTAssertEqual(engine.planner.focus?.limit, 1500)
    }

    func testStartTimerValidatesMinutes() {
        let (varEngine, _) = makeEngine()
        var engine = varEngine
        for bad in [0, -5, 721] {
            XCTAssertThrowsError(try engine.startTimer(task: nil, minutes: bad)) { e in
                XCTAssertTrue("\(e)".contains("1 to 720"), "\(e)")
            }
        }
    }

    func testStartTimerRejectsFutureAndDoneTasks() throws {
        let (varEngine, _) = makeEngine()
        var engine = varEngine
        _ = try engine.addTasks(["future thing tomorrow"])
        XCTAssertThrowsError(
            try engine.startTimer(task: try Fixture.taskID("future thing", in: engine.planner), minutes: nil))

        _ = try engine.addTasks(["a"])
        _ = try engine.complete(try Fixture.taskID("a", in: engine.planner))
        XCTAssertThrowsError(try engine.startTimer(task: try Fixture.taskID("a", in: engine.planner), minutes: nil)) {
            e in
            XCTAssertTrue("\(e)".contains("Reopen this task before starting focus"), "\(e)")
        }
    }

    func testCompleteStopsAPausedTimerWithoutDoubleCounting() throws {
        let (varEngine, setClock) = makeEngine()
        var engine = varEngine
        _ = try engine.addTasks(["a"])
        try engine.startTimer(task: try Fixture.taskID("a", in: engine.planner), minutes: 25)
        setClock(10)
        try engine.pauseTimer()
        _ = try engine.complete(try Fixture.taskID("a", in: engine.planner))
        XCTAssertNil(engine.planner.focus)
        XCTAssertEqual(engine.planner.tasks[0].focusedSeconds, 600, accuracy: 0.5)
        XCTAssertEqual(engine.planner.focusSegments.count, 1)
    }

    func testDeleteClearsTheTimerForItsTask() throws {
        let (varEngine, setClock) = makeEngine()
        var engine = varEngine
        _ = try engine.addTasks(["a"])
        try engine.startTimer(task: try Fixture.taskID("a", in: engine.planner), minutes: 25)
        setClock(5)
        _ = try engine.delete(try Fixture.taskID("a", in: engine.planner), on: .day("2026-11-09"))
        XCTAssertNil(engine.planner.focus)
    }

    func testTimerGuards() throws {
        let (varEngine, _) = makeEngine()
        var engine = varEngine
        XCTAssertThrowsError(try engine.pauseTimer())
        XCTAssertThrowsError(try engine.resumeTimer())

        try engine.startTimer(task: nil, minutes: 5)
        XCTAssertThrowsError(try engine.resumeTimer()) { e in
            XCTAssertTrue("\(e)".contains("not on hold"), "\(e)")
        }
        try engine.pauseTimer()
        XCTAssertThrowsError(try engine.pauseTimer()) { e in
            XCTAssertTrue("\(e)".contains("running"), "\(e)")
        }
    }

    func testSubSecondSessionsAreNotRecorded() throws {
        let (varEngine, setClock) = makeEngine()
        var engine = varEngine
        try engine.startTimer(task: nil, minutes: 5)
        setClock(0.5 / 60)
        let seg = engine.stopTimer()
        XCTAssertNotNil(seg)
        XCTAssertTrue(engine.planner.focusSegments.isEmpty, "segments under a second are dropped")
    }

    func testStopwatchAttributesFocusToTheTaskAndInsights() throws {
        let (varEngine, setClock) = makeEngine()
        var engine = varEngine
        let task = try engine.addTasks(["a"]).first!
        _ = try engine.startStopwatch(taskID: task.id)
        setClock(60)
        XCTAssertEqual(
            engine.insights().today.focusSeconds, 3600, accuracy: 1, "a running session shows up in Insights")
        engine.stopTimer()
        XCTAssertEqual(engine.planner.tasks[0].focusedSeconds, 3600, accuracy: 1)
        XCTAssertEqual(engine.insights().today.focusSeconds, 3600, accuracy: 1)
    }

    func testCountdownAcrossSpringForwardUsesRealSeconds() throws {
        // 2027-03-14 01:50 PST + 20 real minutes lands at 03:10 PDT, not 02:10.
        let start = Fixture.date("2027-03-14 01:50")
        final class Box { var clock: Date; init(_ d: Date) { clock = d } }
        let box = Box(start)
        var engine = PlannerEngine(planner: Planner(), now: { box.clock }, calendar: Fixture.calendar)
        _ = try engine.addTasks(["dst run"])
        try engine.startTimer(task: try Fixture.taskID("dst run", in: engine.planner), minutes: 20)
        box.clock = start.addingTimeInterval(1200)
        XCTAssertTrue(engine.tick())
        XCTAssertEqual(engine.planner.tasks[0].focusedSeconds, 1200, accuracy: 0.5)
    }
}
