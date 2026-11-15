import Foundation
import PlannerCore
import XCTest
@testable import PerchUI

final class NotchStripQueueTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ kind: NotchStripQueue.Kind, _ id: String, after seconds: Double = 0) -> NotchStripQueue.Item {
        .init(id: id, kind: kind, createdAt: now.addingTimeInterval(seconds))
    }

    func testPriorityMatchesTheStripTableRegardlessOfInsertionOrder() {
        var queue = NotchStripQueue()
        let kinds = NotchStripQueue.Kind.allCases
        queue.reconcile(kinds.reversed().map { item($0, $0.rawValue) }, at: now)
        for kind in kinds {
            XCTAssertEqual(queue.current?.kind, kind)
            queue.answer(kind.rawValue, at: now)
        }
        XCTAssertNil(queue.current)
        XCTAssertNil(queue.nextChange)
    }

    func testSamePriorityIsOldestFirstThenStableID() {
        for candidates in [
            [item(.reminder, "b"), item(.reminder, "a"), item(.reminder, "c", after: -1)],
            [item(.reminder, "c", after: -1), item(.reminder, "a"), item(.reminder, "b")],
        ] {
            var queue = NotchStripQueue()
            queue.reconcile(candidates, at: now)
            XCTAssertEqual(queue.current?.id, "c")
            queue.answer("c", at: now)
            XCTAssertEqual(queue.current?.id, "a")
        }
    }

    func testAnswerAndTimeoutDedupeUntilOccurrenceLeavesTheSource() {
        var queue = NotchStripQueue()
        let undo = item(.undo, "undo")
        queue.reconcile([undo, undo], at: now)
        XCTAssertEqual(queue.pending.count, 1)
        queue.advance(to: now.addingTimeInterval(6))
        XCTAssertNil(queue.current)
        queue.reconcile([undo], at: now.addingTimeInterval(7))
        XCTAssertNil(queue.current)
        queue.reconcile([], at: now.addingTimeInterval(8))
        queue.reconcile([undo], at: now.addingTimeInterval(9))
        XCTAssertEqual(queue.current, undo)
        queue.answer(undo.id, at: now.addingTimeInterval(9))
        queue.reconcile([undo], at: now.addingTimeInterval(10))
        XCTAssertNil(queue.current)
    }

    func testTimeoutsAreSixAndTenSecondsOfVisibleTimeNotTimeBehindAReminder() {
        for (kind, duration) in [(NotchStripQueue.Kind.undo, 6.0), (.agentChange, 10.0)] {
            var queue = NotchStripQueue()
            let timed = item(kind, "timed")
            let reminder = item(.reminder, "reminder", after: 2)
            queue.reconcile([timed], at: now)
            XCTAssertEqual(queue.nextChange, now.addingTimeInterval(duration))
            queue.reconcile([timed, reminder], at: now.addingTimeInterval(2))
            queue.advance(to: now.addingTimeInterval(3600))
            XCTAssertEqual(queue.current?.id, "reminder")
            queue.answer("reminder", at: now.addingTimeInterval(3600))
            XCTAssertEqual(queue.current?.id, "timed")
            XCTAssertEqual(queue.nextChange, now.addingTimeInterval(3600 + duration - 2))
            queue.advance(to: now.addingTimeInterval(3600 + duration - 2))
            XCTAssertNil(queue.current)
        }
    }

    func testPersistentKindsNeverTimeOutAndUndoProgressDrains() {
        for kind in [NotchStripQueue.Kind.dataProblem, .reminder, .blockEnded, .headsUp, .dropShelf] {
            var queue = NotchStripQueue()
            queue.reconcile([item(kind, "persistent")], at: now)
            queue.advance(to: now.addingTimeInterval(86_400))
            XCTAssertEqual(queue.current?.id, "persistent")
            XCTAssertNil(queue.nextChange)
        }
        var queue = NotchStripQueue()
        queue.reconcile([item(.undo, "undo")], at: now)
        XCTAssertEqual(queue.remainingFraction(at: now.addingTimeInterval(3)), 0.5, accuracy: 0.001)
        queue.reconcile([item(.undo, "undo")], at: now.addingTimeInterval(3))
        XCTAssertEqual(queue.nextChange, now.addingTimeInterval(6), "Refresh must not restart the timeout")
    }

    func testHardDeadlineExpiresPendingAgentDeletionEvenWhilePreempted() {
        var queue = NotchStripQueue()
        let pending = NotchStripQueue.Item(
            id: "delete", kind: .agentChange, createdAt: now, deadline: now.addingTimeInterval(10))
        queue.reconcile([pending, item(.reminder, "reminder")], at: now)
        XCTAssertEqual(queue.nextChange, now.addingTimeInterval(10))
        queue.advance(to: now.addingTimeInterval(10))
        queue.answer("reminder", at: now.addingTimeInterval(10))
        XCTAssertNil(queue.current)
    }

    func testFutureBoundaryAndBackwardClockDoNotSpendTheBudgetTwice() {
        var queue = NotchStripQueue()
        queue.reconcile([item(.undo, "future", after: 5)], at: now)
        XCTAssertNil(queue.current)
        XCTAssertEqual(queue.nextChange, now.addingTimeInterval(5))
        queue.advance(to: now.addingTimeInterval(5))
        queue.advance(to: now.addingTimeInterval(7))
        queue.advance(to: now.addingTimeInterval(6))
        XCTAssertEqual(queue.remainingFraction(at: now.addingTimeInterval(7)), 4.0 / 6, accuracy: 0.001)
        queue.advance(to: now.addingTimeInterval(11))
        XCTAssertNil(queue.current)
    }

    func testPolicyReadsLiveHeadsUpAndReminderPreferences() {
        var planner = Planner()
        let task = PlanTask(title: "Call the bank", day: "2027-01-15", remindAt: now.addingTimeInterval(-120))
        planner.tasks = [task]
        XCTAssertEqual(NotchStripPolicy.reminders(in: planner, at: now).map(\.id), [task.id])
        planner.preferences.persistentReminders = false
        XCTAssertTrue(NotchStripPolicy.reminders(in: planner, at: now).isEmpty)
        planner.focus = FocusSession(taskID: task.id, limit: 600, now: now)
        XCTAssertNil(NotchStripPolicy.headsUp(in: planner, at: now))
        planner.preferences.blockHeadsUp = .tenMinutes
        XCTAssertNotNil(NotchStripPolicy.headsUp(in: planner, at: now))
        planner.preferences.blockHeadsUp = .off
        XCTAssertNil(NotchStripPolicy.headsUp(in: planner, at: now))
        planner.preferences.blockHeadsUp = .fiveMinutes
        XCTAssertNotNil(NotchStripPolicy.headsUp(in: planner, at: now.addingTimeInterval(300)))
        planner.focus?.state = .paused
        XCTAssertNil(NotchStripPolicy.headsUp(in: planner, at: now.addingTimeInterval(300)))
        planner.focus?.state = .finished
        XCTAssertTrue(NotchStripPolicy.showsBlockEnded(in: planner))
        planner.preferences.blockEndAction = .takeBreak
        XCTAssertFalse(NotchStripPolicy.showsBlockEnded(in: planner))
        planner.preferences.blockEndAction = .doNothing
        XCTAssertFalse(NotchStripPolicy.showsBlockEnded(in: planner))
    }
}
