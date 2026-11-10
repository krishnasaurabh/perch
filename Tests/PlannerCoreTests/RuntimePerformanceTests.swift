import Foundation
import XCTest
@testable import PlannerCore
#if canImport(Glibc)
    import Glibc
#else
    import Darwin
#endif

final class RuntimePerformanceTests: XCTestCase {
    func testSyntheticTimerWorkload() throws {
        for count in [10, 1_000] {
            var measurements: [(reads: Int, decodes: Int, writes: Int, seconds: Double)] = []
            for scheduled in [false, true] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                var reads = 0, decodes = 0, writes = 0
                var io = PlannerFile.IO()
                io.read = { url in
                    if url.lastPathComponent == "planner.json" { reads += 1 }
                    return try Data(contentsOf: url)
                }
                io.didDecode = { decodes += 1 }
                io.write = { data, url in
                    if url.lastPathComponent == "planner.json" { writes += 1 }
                    try data.write(to: url, options: .atomic)
                }
                let file = PlannerFile(
                    url: root.appendingPathComponent("planner.json"), io: io,
                    preferences: MemoryPlannerPreferences())
                var now = Date(timeIntervalSince1970: 1_800_000_000)
                let pipeline = PlannerCommandPipeline(file: file, clock: ClosurePlannerClock { now })
                var planner = Planner()
                planner.tasks = (0..<count).map { PlanTask(title: "Synthetic task \($0)", day: "2027-01-15") }
                planner.focus = FocusSession(taskID: planner.tasks[0].id, limit: 300, now: now)
                try file.save(planner)
                reads = 0; decodes = 0; writes = 0
                let started = Date()
                var next = FocusUpdateSchedule.nextUpdate(for: planner.focus, now: now)
                for _ in 0..<31 {
                    now.addTimeInterval(1)
                    if !scheduled || next.map({ now >= $0 }) == true {
                        let result = try pipeline.execute(.tick, origin: .background)
                        next = FocusUpdateSchedule.nextUpdate(for: result.state.focus, now: now)
                    }
                }
                let seconds = Date().timeIntervalSince(started)
                measurements.append((reads, decodes, writes, seconds))
                print(
                    "timer-workload scheduled=\(scheduled) tasks=\(count) reads=\(reads) decodes=\(decodes) writes=\(writes) seconds=\(seconds)"
                )
                XCTAssertEqual(writes, 1, "Keep the 30-second durable checkpoint")
                let saved = try file.load()
                XCTAssertEqual(saved.tasks[0].focusedSeconds, 30)
                XCTAssertEqual(saved.focus?.banked, 30)
            }
            XCTAssertEqual(measurements[0].reads, 63)
            XCTAssertLessThanOrEqual(measurements[1].reads, 10, "Display seconds must not load the whole planner")
            XCTAssertLessThan(measurements[1].decodes, measurements[0].decodes / 4)
            // Timings are evidence, not a noisy machine-dependent CI threshold.
        }
    }

    func testCountdownSchedulesCompletionBeforeCheckpoint() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let focus = FocusSession(taskID: nil, limit: 7.25, now: now)
        XCTAssertEqual(FocusUpdateSchedule.nextUpdate(for: focus, now: now), now.addingTimeInterval(7.25))
        XCTAssertEqual(
            FocusUpdateSchedule.nextUpdate(for: focus, now: now.addingTimeInterval(20)), now.addingTimeInterval(20))
    }

    func testStopwatchSchedulesCheckpointAndPausedHasNoWake() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var focus = FocusSession(taskID: nil, limit: nil, now: now)
        XCTAssertEqual(FocusUpdateSchedule.nextUpdate(for: focus, now: now), now.addingTimeInterval(30))
        _ = focus.checkpoint(at: now.addingTimeInterval(30))
        XCTAssertEqual(
            FocusUpdateSchedule.nextUpdate(for: focus, now: now.addingTimeInterval(31)), now.addingTimeInterval(60))
        _ = focus.pause(at: now.addingTimeInterval(31))
        XCTAssertNil(FocusUpdateSchedule.nextUpdate(for: focus, now: now))
        XCTAssertNil(FocusUpdateSchedule.nextUpdate(for: nil, now: now))
    }

    func testClockBackwardsDoesNotAccrueOrCreateTightLoop() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let focus = FocusSession(taskID: nil, limit: 60, now: now)
        let earlier = now.addingTimeInterval(-3_600)
        XCTAssertEqual(focus.elapsed(at: earlier), 0)
        XCTAssertEqual(FocusUpdateSchedule.nextUpdate(for: focus, now: earlier), now.addingTimeInterval(30))
    }

    func testResetHourReschedulesAcrossDSTAndPreferenceChanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-03-14T09:00:00Z"))
        var planner = Planner()
        planner.preferences.resetHour = 2
        let next = FocusUpdateSchedule.nextDay(for: planner, now: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: next), 3)
        XCTAssertEqual(calendar.component(.day, from: next), 14)
        planner.preferences.resetHour = 4
        XCTAssertEqual(
            calendar.component(.hour, from: FocusUpdateSchedule.nextDay(for: planner, now: now, calendar: calendar)), 4)
    }

    func testRevisionDetectsAtomicReplacementWithSameDateAndSize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("planner.json")
        try Data("first".utf8).write(to: url, options: .atomic)
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: url.path)
        let first = try XCTUnwrap(PlannerFileRevision(url: url))
        try Data("other".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: first.modified], ofItemAtPath: url.path)
        let second = try XCTUnwrap(PlannerFileRevision(url: url))
        XCTAssertEqual(second.size, first.size)
        XCTAssertEqual(second.modified, first.modified)
        XCTAssertNotEqual(second.identity, first.identity)
        XCTAssertNotEqual(second, first)
    }

    func testInteractiveLockFailsFastWithoutReadingOrChangingData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        try file.save(Planner())
        let original = try Data(contentsOf: file.url)
        let fd = open(file.lockURL.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { _ = flock(fd, LOCK_UN); close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let started = Date()
        XCTAssertThrowsError(try file.avoidingLockWaits().load()) { XCTAssertTrue($0 is PlannerStorageBusy) }
        let pipeline = PlannerCommandPipeline(file: file.avoidingLockWaits())
        XCTAssertThrowsError(try pipeline.execute(.tick, origin: .background)) {
            XCTAssertTrue($0 is PlannerStorageBusy)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertEqual(try Data(contentsOf: file.url), original)
    }
}
