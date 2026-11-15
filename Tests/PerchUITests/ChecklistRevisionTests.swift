import Foundation
import PlannerCore
@testable import PerchUI
import XCTest

final class ChecklistRevisionTests: XCTestCase {
    func testSuccessfulSecondRecordingPreservesFailedSpeechAndDestination() {
        var capture = TodayTaskCapture()
        let parent = UUID()
        capture.text = "Still typing"
        XCTAssertFalse(capture.submitDictation("First unsaved step", parentID: parent) { _ in false })
        XCTAssertTrue(capture.submitDictation("Second recording") { $0 == "Second recording" })
        XCTAssertEqual(capture.pendingDictation, "First unsaved step")
        XCTAssertEqual(capture.pendingDictationParentID, parent)
        XCTAssertEqual(capture.text, "Still typing")
    }

    func testFailedSecondRecordingPreservesOldestSpeechAndDestination() {
        var capture = TodayTaskCapture()
        let firstParent = UUID()
        let secondParent = UUID()
        XCTAssertFalse(capture.submitDictation("First unsaved step", parentID: firstParent) { _ in false })
        XCTAssertFalse(capture.submitDictation("Second unsaved step", parentID: secondParent) { _ in false })
        XCTAssertEqual(capture.pendingDictation, "First unsaved step")
        XCTAssertEqual(capture.pendingDictationParentID, firstParent)
        XCTAssertFalse(
            capture.retryDictation { text, parent in
                XCTAssertEqual(text, "First unsaved step")
                XCTAssertEqual(parent, firstParent)
                return false
            })
        XCTAssertTrue(
            capture.retryDictation { text, parent in
                text == "First unsaved step" && parent == firstParent
            })
        XCTAssertEqual(capture.pendingDictation, "Second unsaved step")
        XCTAssertEqual(capture.pendingDictationParentID, secondParent)
        XCTAssertTrue(
            capture.retryDictation { text, parent in
                text == "Second unsaved step" && parent == secondParent
            })
        XCTAssertNil(capture.pendingDictation)
        XCTAssertFalse(
            capture.retryDictation { _, _ in
                XCTFail("No recording to retry"); return true
            })
    }

    func testIdenticalFailedRecordingsAreRetainedIndependently() {
        var capture = TodayTaskCapture()
        XCTAssertFalse(capture.submitDictation("Same words") { _ in false })
        XCTAssertFalse(capture.submitDictation("Same words") { _ in false })
        XCTAssertTrue(capture.retryDictation { _, _ in true })
        XCTAssertEqual(capture.pendingDictation, "Same words")
        XCTAssertTrue(capture.retryDictation { _, _ in true })
        XCTAssertNil(capture.pendingDictation)
    }

    func testCompletedParentFailureSurvivesNewTaskUntilOriginalCanBeRetried() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let file = PlannerFile(url: root.appendingPathComponent("planner.json"))
        let pipeline = PlannerCommandPipeline(file: file, clock: ClosurePlannerClock { now })
        let parent = try pipeline.perform(origin: .user) {
            try $0.addTasks(["Parent"], on: .day($0.today))
        }.value[0]
        _ = try pipeline.perform(origin: .user) { try $0.complete(parent.id) }
        let day = try XCTUnwrap(parent.day)
        var capture = TodayTaskCapture()
        capture.text = "Typed draft"
        func submit(_ text: String, _ parentID: UUID?) -> Bool {
            do {
                _ = try pipeline.perform(origin: .user) {
                    try TodayTaskCapture.submit(text, parentID: parentID, on: .day(day), commands: $0)
                }
                return true
            } catch { return false }
        }
        XCTAssertFalse(capture.submitDictation("First unsaved step", parentID: parent.id) { submit($0, parent.id) })
        XCTAssertTrue(capture.submitDictation("Second recording") { submit($0, nil) })
        XCTAssertFalse(capture.retryDictation(using: submit))
        XCTAssertEqual(capture.pendingDictation, "First unsaved step")
        XCTAssertEqual(capture.pendingDictationParentID, parent.id)
        XCTAssertEqual(try file.load().tasks.map(\.title), ["Parent", "Second recording"])
        _ = try pipeline.perform(origin: .user) { try $0.reopen(parent.id) }
        XCTAssertTrue(capture.retryDictation(using: submit))
        XCTAssertEqual(try file.load().tasks.first?.steps.map(\.title), ["First unsaved step"])
        XCTAssertNil(capture.pendingDictation)
        XCTAssertEqual(capture.text, "Typed draft")
    }

    func testCompletionDrivenExpansionSharesTheSameFoldState() throws {
        var tasks = (0..<6).map { PlanTask(title: "Task \($0)", day: "2026-11-13") }
        let selected = tasks[3].id
        tasks[3].done = true
        let ordered = TodayTaskNavigation.ordered(tasks, currentID: nil)
        let expanded = TodayTaskNavigation.isExpanded(ordered, expanded: false, selectedID: selected)
        XCTAssertTrue(expanded)
        XCTAssertEqual(TodayTaskNavigation.visible(ordered, expanded: false, selectedID: selected).count, 6)
        XCTAssertEqual(
            TodayTaskNavigation.move(in: ordered.map(\.id), from: .task(selected), offset: 1, expanded: expanded), .fold
        )
        XCTAssertEqual(
            TodayTaskNavigation.move(in: ordered.map(\.id), from: .fold, offset: -1, expanded: expanded),
            .task(selected))
        let collapsed = !expanded
        XCTAssertEqual(
            TodayTaskNavigation.visible(ordered, expanded: collapsed, selectedID: ordered.first?.id).count, 4)
    }

    func testArrowNavigationReachesFoldAndReturnsToVisibleRowsAfterCollapse() throws {
        let ids = (0..<6).map { _ in UUID() }
        var current = TodayTaskNavigation.Destination.task(ids[0])
        var expanded = false
        for id in ids.dropFirst() {
            current = try XCTUnwrap(TodayTaskNavigation.move(in: ids, from: current, offset: 1, expanded: expanded))
            XCTAssertEqual(current, .task(id))
            if id == ids[4] { expanded = true }
        }
        current = try XCTUnwrap(TodayTaskNavigation.move(in: ids, from: current, offset: 1, expanded: expanded))
        XCTAssertEqual(current, .fold)
        XCTAssertEqual(TodayTaskNavigation.move(in: ids, from: current, offset: -1, expanded: true), .task(ids[5]))
        expanded = false
        XCTAssertEqual(TodayTaskNavigation.move(in: ids, from: current, offset: -1, expanded: expanded), .task(ids[3]))
        XCTAssertEqual(TodayTaskNavigation.move(in: ids, from: current, offset: 1, expanded: expanded), .fold)
        XCTAssertNil(TodayTaskNavigation.move(in: [], from: current, offset: -1, expanded: false))
        XCTAssertEqual(
            TodayTaskNavigation.move(in: Array(ids.prefix(4)), from: .task(ids[3]), offset: 1, expanded: false),
            .task(ids[3]))
    }
}
