import XCTest
@testable import PlannerCore

final class FocusLogTests: XCTestCase {
    var clock = Fixture.now
    lazy var engine = PlannerEngine(
        planner: Planner(), now: { [unowned self] in self.clock }, calendar: Fixture.calendar)

    func testTickCheckpointsAtThirtySecondsWithoutFinishingOrDoubleCounting() throws {
        let task = try engine.addTasks(["work"]).first!
        try engine.startTimer(task: task.id.uuidString, minutes: 2)
        clock += 29
        XCTAssertFalse(engine.tick())
        XCTAssertTrue(engine.planner.focusLog.isEmpty)
        clock += 1
        XCTAssertFalse(engine.tick())
        XCTAssertEqual(engine.planner.focusLog.reduce(0) { $0 + $1.seconds }, 30)
        XCTAssertEqual(engine.planner.tasks[0].focusedSeconds, 30)
        XCTAssertEqual(engine.planner.focus?.elapsed(at: clock), 30)
        XCTAssertEqual(engine.planner.focus?.state, .running)
        XCTAssertFalse(engine.tick())
        XCTAssertEqual(engine.planner.focusLog.count, 1)
        clock += 15
        XCTAssertEqual(engine.insights().today.focusSeconds, 45)
        try engine.pauseTimer()
        clock += 600
        XCTAssertFalse(engine.checkpointFocus())
        try engine.resumeTimer()
        clock += 90
        XCTAssertTrue(engine.tick())
        XCTAssertEqual(engine.planner.focusLog.reduce(0) { $0 + $1.seconds }, 120)
        XCTAssertEqual(engine.planner.tasks[0].focusedSeconds, 120)
        XCTAssertFalse(engine.checkpointFocus())
    }

    func testExplicitCheckpointBanksSubsecondTimeAndStopOnlyRecordsTail() {
        engine.startStopwatch(taskID: nil)
        clock += 0.5
        XCTAssertTrue(engine.checkpointFocus())
        XCTAssertEqual(engine.planner.focusLog.first?.seconds, 0.5)
        XCTAssertFalse(engine.checkpointFocus())
        clock += 12.5
        _ = engine.stopTimer()
        XCTAssertEqual(engine.planner.focusLog.reduce(0) { $0 + $1.seconds }, 13)
    }

    func testPersistedCheckpointSurvivesRestartAndDoesNotCreditOfflineGap() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = PlannerFile(url: dir.appendingPathComponent("planner.json"))
        engine.startStopwatch(taskID: nil)
        clock += 30
        XCTAssertFalse(engine.tick())
        try file.save(engine.planner)
        clock += 4000
        let persisted = try file.load()
        XCTAssertEqual(persisted.focusLog.reduce(0) { $0 + $1.seconds }, 30)
        XCTAssertEqual(persisted.focus?.banked, 30)
        var recovered = PlannerEngine(planner: persisted, now: { self.clock }, calendar: Fixture.calendar)
        XCTAssertTrue(recovered.recoverFocus())
        XCTAssertEqual(recovered.planner.focus?.state, .paused)
        XCTAssertEqual(recovered.planner.focus?.elapsed(at: clock), 30)
        XCTAssertFalse(recovered.recoverFocus())
        try recovered.resumeTimer()
        clock += 10
        _ = recovered.stopTimer()
        XCTAssertEqual(recovered.planner.focusLog.reduce(0) { $0 + $1.seconds }, 40)
    }

    func testSubsecondCheckpointsRoundTripWithoutPhantomFocus() throws {
        clock += 0.123456
        engine.startStopwatch(taskID: nil)
        clock += 30.751234
        XCTAssertTrue(engine.checkpointFocus())
        let before = engine.planner
        engine.planner = try PlannerFile.decoder.decode(Planner.self, from: PlannerFile.encoder.encode(before))
        XCTAssertEqual(engine.planner, before)
        XCTAssertFalse(engine.checkpointFocus(), "same instant must not accrue time after persistence")
        XCTAssertEqual(
            engine.planner.focusLog.reduce(0) { $0 + $1.seconds }, before.focusLog.reduce(0) { $0 + $1.seconds })
        clock += 0.125678
        _ = engine.stopTimer()
        XCTAssertEqual(engine.planner.focusLog.reduce(0) { $0 + $1.seconds }, 30.876912, accuracy: 0.000001)
    }

    func testActivitySplitsHoursClipsSinceAndIgnoresInvalidIntervals() {
        engine.planner.focusLog = [
            FocusSegment(taskID: nil, start: Fixture.date("2026-11-09 09:50"), end: Fixture.date("2026-11-09 11:10")),
            FocusSegment(taskID: nil, start: Fixture.date("2026-11-08 09:00"), end: Fixture.date("2026-11-08 09:10")),
            FocusSegment(taskID: nil, start: Fixture.now, end: Fixture.now.addingTimeInterval(-60)),
        ]
        let hours = engine.activityByHour(since: Fixture.date("2026-11-09 09:55"))
        XCTAssertEqual(hours[9], 300)
        XCTAssertEqual(hours[10], 3600)
        XCTAssertEqual(hours[11], 600)
        XCTAssertEqual(hours.count, 3)
        XCTAssertEqual(engine.insights().peakHours, [10, 9, 11], "equal totals tie by ascending hour")
    }

    func testActivityIncludesOnlyCappedRunningTailAndNotPausedTime() throws {
        clock = Fixture.date("2026-11-09 09:59")
        try engine.startTimer(task: nil, minutes: 2)
        clock += 180
        let hours = engine.activityByHour(since: Fixture.date("2026-11-09 00:00"))
        XCTAssertEqual(hours[9], 60)
        XCTAssertEqual(hours[10], 60)
        XCTAssertEqual(engine.insights().today.focusSeconds, 120)
        XCTAssertTrue(engine.tick())
        XCTAssertEqual(engine.activityByHour(since: Fixture.date("2026-11-09 00:00")), hours)
    }

    func testFocusSummariesSplitAtResetBoundaryAndMidnight() {
        clock = Fixture.date("2026-11-10 04:10")
        engine.planner.preferences.resetHour = 4
        engine.planner.focusLog = [FocusSegment(taskID: nil, start: Fixture.date("2026-11-10 03:50"), end: clock)]
        XCTAssertEqual(engine.insights().today.focusSeconds, 600)
        XCTAssertEqual(engine.insights().lastSeven.dropLast().last?.focusSeconds, 600)
        engine.planner.preferences.resetHour = 0
        engine.planner.focusLog = [
            FocusSegment(taskID: nil, start: Fixture.date("2026-11-09 23:50"), end: Fixture.date("2026-11-10 00:10"))
        ]
        XCTAssertEqual(engine.insights().today.focusSeconds, 600)
        XCTAssertEqual(engine.insights().allTimeFocusSeconds, 1200)
    }

    func testHourlyActivityHandlesBothDSTTransitionsByElapsedTime() {
        for (start, end, expected) in [
            ("2026-03-08 01:30", "2026-03-08 03:30", [1: 1800.0, 3: 1800.0]),
            ("2026-11-01 00:30", "2026-11-01 02:30", [0: 1800.0, 1: 7200.0, 2: 1800.0]),
        ] {
            engine.planner.focusLog = [FocusSegment(taskID: nil, start: Fixture.date(start), end: Fixture.date(end))]
            XCTAssertEqual(engine.activityByHour(since: Fixture.date("2026-01-01 00:00")), expected)
        }
    }
}
