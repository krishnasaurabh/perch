import Foundation
import PlannerTestSupport
import XCTest
@testable import PlannerCore

final class FocusHistoryStorageTests: XCTestCase {
    private func syntheticLog(count: Int) -> [FocusSegment] {
        let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        return (0..<count).map {
            let start = Fixture.now.addingTimeInterval(Double($0) * 37.5 + 0.123456789)
            return FocusSegment(taskID: $0 % 3 == 0 ? a : nil, start: start, end: start + 17.25)
        }
    }

    func testLargeLogIsPackedButExactIntervalsAndQueriesSurvive() throws {
        var p = Planner()
        p.focusSegments = syntheticLog(count: 12_000)
        let encoded = try PlannerFile.encoder.encode(PlannerDiskDocument(p))
        let restored = try PlannerFile.decoder.decode(PlannerDiskDocument.self, from: encoded).planner
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual((json["focusSegments"] as? [Any])?.count, FocusHistoryStorage.recentLimit)
        XCTAssertFalse((json["focusHistory"] as? [Any] ?? []).isEmpty)
        XCTAssertEqual(
            restored.focusSegments, p.focusSegments, "No gap, identity, fraction or interval boundary may change")
        XCTAssertEqual(
            restored.focusSegments.reduce(0) { $0 + $1.seconds }, p.focusSegments.reduce(0) { $0 + $1.seconds })
        for pair in zip(restored.focusSegments, restored.focusSegments.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.end, pair.1.start)
        }
        let before = PlannerEngine(planner: p, now: { Fixture.now + 600_000 }, calendar: Fixture.calendar)
        let after = PlannerEngine(planner: restored, now: { Fixture.now + 600_000 }, calendar: Fixture.calendar)
        for since in [Fixture.now - 1, Fixture.now + 123.123, Fixture.now + 301_000] {
            XCTAssertEqual(after.activityByHour(since: since), before.activityByHour(since: since))
            XCTAssertEqual(after.insights(), before.insights())
        }
        let verbose = try PlannerFile.encoder.encode(p)
        XCTAssertLessThan(encoded.count, verbose.count)
        XCTAssertEqual(
            try PlannerFile.encoder.encode(PlannerDiskDocument(restored)), encoded, "Packing must be idempotent")
    }

    func testPendingAndCurrentRecordsStayVerbatimInWorkingLog() throws {
        var p = Planner()
        p.focusSegments = syntheticLog(count: 4_000)
        p.focusSegments[0].isSynced = false
        p.focusSegments[2_000].isSynced = false
        p.focus = FocusSession(taskID: nil, limit: nil, now: p.focusSegments[3_000].start)
        let stored = FocusHistoryStorage(p.focusSegments, current: p.focus)
        XCTAssertTrue(stored.recent.contains(p.focusSegments[0]))
        XCTAssertTrue(stored.recent.contains(p.focusSegments[2_000]))
        for segment in p.focusSegments.suffix(1_000) { XCTAssertTrue(stored.recent.contains(segment)) }
        XCTAssertEqual(stored.recent.count, 1_002, "Only explicitly protected records may exceed the working limit")
        XCTAssertEqual(
            try FocusHistoryStorage.restore(
                archive: stored.archive, recent: stored.recent, indices: stored.recentIndices), p.focusSegments)
    }

    func testPackingNeverMergesOverlapOrFillsPausedGaps() throws {
        var p = Planner()
        let start = Fixture.now
        p.focusSegments = (0..<600).map { _ in FocusSegment(taskID: nil, start: start, end: start + 10.25) }
        let encoded = try PlannerFile.encoder.encode(PlannerDiskDocument(p))
        XCTAssertEqual(
            try PlannerFile.decoder.decode(PlannerDiskDocument.self, from: encoded).planner.focusSegments,
            p.focusSegments)
    }

    func testMalformedPackedTuplesAndIndicesFailClosed() throws {
        for tuple in ["[0,1]", "[-1,1,2]", "[0.5,1,2]", "[0,2,1]", "[0,1,1]"] {
            let raw = Data("{\"intervals\":[\(tuple)]}".utf8)
            XCTAssertThrowsError(try PlannerFile.decoder.decode(PackedFocusHistory.self, from: raw))
        }
        let page = PackedFocusHistory(taskID: nil, intervals: [[0, 1, 2]])
        XCTAssertThrowsError(
            try FocusHistoryStorage.restore(archive: [page], recent: syntheticLog(count: 1), indices: [0]))
        XCTAssertThrowsError(try FocusHistoryStorage.restore(archive: [page], recent: [], indices: [0]))
    }

    func testFractionalCheckpointAfterPackedReloadDoesNotRecount() throws {
        var p = Planner()
        p.focusSegments = syntheticLog(count: 1_000)
        let time = Fixture.now + 100_000.123456789
        p.focus = FocusSession(taskID: nil, limit: nil, now: time)
        var engine = PlannerEngine(planner: p, now: { time + 30.125 }, calendar: Fixture.calendar)
        XCTAssertTrue(engine.checkpointFocus())
        let data = try PlannerFile.encoder.encode(PlannerDiskDocument(engine.planner))
        let decoded = try PlannerFile.decoder.decode(PlannerDiskDocument.self, from: data).planner
        var restored = PlannerEngine(planner: decoded, now: { time + 30.125 }, calendar: Fixture.calendar)
        XCTAssertFalse(restored.checkpointFocus())
        XCTAssertEqual(restored.planner, engine.planner)
    }
}
