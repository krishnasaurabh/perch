import Foundation
import PlannerCore
@testable import PerchUI
import XCTest

final class TodayCaptureRegressionTests: XCTestCase {
    func testDictationPreservesTextTypedBeforeAndDuringRecording() {
        var capture = TodayTaskCapture()
        capture.text = "Unfinished typed task"
        // Recording is asynchronous. The user may keep typing before it finishes.
        capture.text += " with a new detail"
        var submitted: [String] = []
        XCTAssertTrue(
            capture.submitDictation("Spoken task") {
                submitted.append($0); return true
            })
        XCTAssertEqual(submitted, ["Spoken task"])
        XCTAssertEqual(capture.text, "Unfinished typed task with a new detail")
        XCTAssertNil(capture.pendingDictation)
    }

    func testFailedDictationRetainsBothDraftsForRetry() {
        var capture = TodayTaskCapture()
        capture.text = "Keep my typed task"
        XCTAssertFalse(capture.submitDictation("  Spoken task  ") { _ in false })
        XCTAssertEqual(capture.text, "Keep my typed task")
        XCTAssertEqual(capture.pendingDictation, "Spoken task")
        capture.text += " and later typing"
        XCTAssertTrue(capture.retryDictation { text, parentID in text == "Spoken task" && parentID == nil })
        XCTAssertEqual(capture.text, "Keep my typed task and later typing")
        XCTAssertNil(capture.pendingDictation)
    }

    func testEmptyDictationDoesNotSubmitOrDiscardPendingSpeech() {
        var capture = TodayTaskCapture()
        XCTAssertFalse(capture.submitDictation("Retry me") { _ in false })
        XCTAssertFalse(
            capture.submitDictation(" \n ") { _ in
                XCTFail("Empty speech submitted"); return true
            })
        XCTAssertEqual(capture.pendingDictation, "Retry me")
    }

    func testEmptySecondRecordingRetainsFailedStepDestination() {
        var capture = TodayTaskCapture()
        let parent = UUID()
        XCTAssertTrue(capture.indent(parentID: parent))
        XCTAssertFalse(capture.submitDictation("Unsubmitted step", parentID: parent) { _ in false })
        XCTAssertTrue(capture.outdent())
        XCTAssertFalse(
            capture.submitDictation(" ", parentID: nil) { _ in
                XCTFail("Empty speech submitted"); return true
            })
        XCTAssertEqual(capture.pendingDictation, "Unsubmitted step")
        XCTAssertEqual(capture.pendingDictationParentID, parent)
        XCTAssertTrue(capture.retryDictation { text, parentID in text == "Unsubmitted step" && parentID == parent })
        XCTAssertNil(capture.pendingDictation)
        XCTAssertNil(capture.pendingDictationParentID)
    }

    func testMultilinePreviewCannotCombineDifferentTasksMetadata() throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-13T09:12:00Z")!
        let parser = TaskCapture(now: now)
        var capture = TodayTaskCapture()
        capture.text = "Call Sam at 1:30 PM\nWrite notes for 20 min"
        XCTAssertNil(capture.preview(using: parser, language: .english))
        var engine = PlannerEngine(planner: Planner(), now: { now })
        let added = try engine.addTasks([capture.text], on: .day(engine.today), language: .english)
        XCTAssertEqual(added.count, 2)
        XCTAssertTrue(added.allSatisfy { $0.startAt == nil })
        XCTAssertEqual(added[1].minutes, 20)
        XCTAssertNotNil(added[0].remindAt)
    }

    func testSingleLinePreviewMatchesSubmissionAndStepHasNoBlock() throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-13T09:12:00Z")!
        let parser = TaskCapture(now: now)
        var capture = TodayTaskCapture()
        capture.text = "\n- Review today at 1:30 PM for 20 min\n"
        let preview = try XCTUnwrap(capture.preview(using: parser, language: .english))
        var engine = PlannerEngine(planner: Planner(), now: { now })
        let added = try engine.addTasks([capture.text], on: .day(engine.today), language: .english)
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added[0].startAt, preview.startAt)
        XCTAssertEqual(added[0].minutes, preview.minutes)
        XCTAssertTrue(capture.indent(parentID: added[0].id))
        XCTAssertNil(capture.preview(using: parser, language: .english))
        XCTAssertTrue(capture.outdent())
        capture.text = " \n "
        XCTAssertNil(capture.preview(using: parser, language: .english))
    }
}
