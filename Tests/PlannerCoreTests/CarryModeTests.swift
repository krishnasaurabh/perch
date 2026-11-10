import PlannerTestSupport
import XCTest
@testable import PlannerCore

final class CarryModeTests: XCTestCase {
    private func engine(
        _ tasks: [PlanTask] = [], mode: CarryMode = .ask,
        at now: Date = Fixture.now, resetHour: Int = 0
    ) -> PlannerEngine {
        var p = Planner()
        p.tasks = tasks
        p.preferences.carryMode = mode
        p.preferences.resetHour = resetHour
        return PlannerEngine(planner: p, now: { now }, calendar: Fixture.calendar)
    }

    func testCarryModeDefaultsAndTolerantDecoding() throws {
        XCTAssertEqual(Preferences().carryMode, .ask)
        XCTAssertEqual(try PlannerFile.decoder.decode(Preferences.self, from: Data("{}".utf8)).carryMode, .ask)
        for (json, expectedError) in [
            (#"{"carryMode":null}"#, "valueNotFound"),
            (#"{"carryMode":"future-value"}"#, "dataCorrupted"),
            (#"{"carryMode":42}"#, "typeMismatch"),
        ] {
            XCTAssertThrowsError(
                try PlannerFile.decoder.decode(Preferences.self, from: Data(json.utf8)),
                "Only an absent preference gets the migration default"
            ) { error in
                let kind: String
                let context: DecodingError.Context
                switch error {
                case DecodingError.valueNotFound(_, let detail): (kind, context) = ("valueNotFound", detail)
                case DecodingError.dataCorrupted(let detail): (kind, context) = ("dataCorrupted", detail)
                case DecodingError.typeMismatch(_, let detail): (kind, context) = ("typeMismatch", detail)
                default: return XCTFail("Expected a typed decoding error, got \(error)")
                }
                XCTAssertEqual(kind, expectedError)
                XCTAssertEqual(context.codingPath.map(\.stringValue), ["carryMode"])
            }
        }
        for mode in CarryMode.allCases {
            var p = Preferences(); p.carryMode = mode; p.resetHour = 4
            XCTAssertEqual(try PlannerFile.decoder.decode(Preferences.self, from: PlannerFile.encoder.encode(p)), p)
        }
    }

    func testAskLeavesOverdueUntouched() {
        let task = PlanTask(title: "Unfinished", day: "2026-11-08")
        var e = engine([task])
        let before = e.planner
        XCTAssertTrue(e.applyCarryMode().isEmpty)
        XCTAssertEqual(e.planner, before)
        XCTAssertEqual(e.overdue().map(\.id), [task.id])
    }

    func testAutoCarriesOnlyEligibleTasksAndPersistsIdempotently() throws {
        let old = PlanTask(
            title: "Old", day: "2026-11-07", steps: [Subtask(title: "step", done: true)],
            focusedSeconds: 90, agentID: "agent")
        let dismissed = PlanTask(title: "Dismissed", day: "2026-11-08")
        let today = PlanTask(title: "Today", day: "2026-11-09")
        let future = PlanTask(title: "Future", day: "2026-11-10")
        let inbox = PlanTask(title: "Inbox", day: nil)
        let done = PlanTask(title: "Done", day: "2026-11-08", done: true, completedAt: Fixture.now)
        let originals = [old, dismissed, today, future, inbox, done]
        var e = engine(originals, mode: .auto)
        e.dismissOverdue([dismissed.id])
        let copies = e.applyCarryMode()
        XCTAssertEqual(copies.count, 1)
        let copy = try XCTUnwrap(copies.first)
        XCTAssertNotEqual(copy.id, old.id)
        XCTAssertEqual(copy.day, e.today)
        XCTAssertEqual(copy.carriedFrom, old.day)
        XCTAssertEqual(copy.carryCount, 1)
        XCTAssertEqual(copy.agentID, "agent")
        XCTAssertEqual(copy.focusedSeconds, 0)
        XCTAssertEqual(copy.steps, old.steps)
        XCTAssertEqual(Array(e.planner.tasks.prefix(originals.count)), originals)
        XCTAssertTrue(e.overdue().isEmpty)
        let persisted = try PlannerFile.decoder.decode(Planner.self, from: PlannerFile.encoder.encode(e.planner))
        var reloaded = PlannerEngine(planner: persisted, now: { Fixture.now }, calendar: Fixture.calendar)
        XCTAssertTrue(reloaded.applyCarryMode().isEmpty)
        XCTAssertEqual(reloaded.planner, persisted)
    }

    func testNeverHandlesWithoutCompletingOrCopyingAndAskDoesNotResurrect() {
        let task = PlanTask(title: "Leave me", day: "2026-11-08")
        var e = engine([task], mode: .never)
        XCTAssertTrue(e.applyCarryMode().isEmpty)
        XCTAssertEqual(e.planner.tasks, [task])
        XCTAssertEqual(e.planner.dismissedOverdue, [task.id])
        let handled = e.planner
        XCTAssertTrue(e.applyCarryMode().isEmpty)
        XCTAssertEqual(e.planner, handled)
        e.planner.preferences.carryMode = .ask
        XCTAssertTrue(e.overdue().isEmpty)
        let newTask = PlanTask(title: "New overdue", day: "2026-11-08")
        e.planner.tasks.append(newTask)
        XCTAssertEqual(e.overdue().map(\.id), [newTask.id])
    }

    func testAutoRespectsLogicalDayAndHandlesNextRollover() throws {
        let now = Fixture.date("2026-11-10 03:59")
        let yesterday = PlanTask(title: "Yesterday", day: "2026-11-08")
        let today = PlanTask(title: "Logical today", day: "2026-11-09")
        var e = engine([yesterday, today], mode: .auto, at: now, resetHour: 4)
        XCTAssertEqual(e.applyCarryMode().map(\.day), ["2026-11-09"])
        e.now = { Fixture.date("2026-11-10 04:00") }
        let next = e.applyCarryMode()
        XCTAssertEqual(next.count, 2)
        XCTAssertTrue(next.allSatisfy { $0.day == "2026-11-10" })
        XCTAssertEqual(next.map(\.carryCount).sorted(), [1, 2])
        XCTAssertTrue(e.applyCarryMode().isEmpty)
    }

    func testAutoDoesNotDuplicateMaterializedRepeat() {
        let task = PlanTask(title: "Repeat", day: "2026-11-08", repeatRule: .daily)
        var e = engine([task], mode: .auto)
        XCTAssertEqual(e.applyRepeats(on: e.today).count, 1)
        XCTAssertTrue(e.applyCarryMode().isEmpty)
        XCTAssertEqual(e.planner.tasks.count, 2)
        XCTAssertTrue(e.overdue().isEmpty)
    }

    func testCompleteOverduePreservesHistoryAndCompletesOnlySelectedTasks() throws {
        let past = PlanTask(
            title: "Finish", day: "2026-11-07", remindAt: Fixture.date("2026-11-07 18:00"),
            priority: .high, notes: "Keep", repeatRule: .daily, minutes: 25,
            steps: [Subtask(title: "step")], focusedSeconds: 90,
            carriedFrom: "2026-11-06", reminderLink: "link", carryCount: 1, agentID: "agent")
        let untouched = PlanTask(title: "Not selected", day: "2026-11-08")
        var e = engine([past, untouched])
        XCTAssertEqual(e.completeOverdue([past.id]).map(\.id), [past.id])
        var expected = past
        expected.done = true; expected.completedAt = Fixture.now; expected.steps[0].done = true
        XCTAssertEqual(e.planner.tasks, [expected, untouched])
        XCTAssertEqual(e.overdue().map(\.id), [untouched.id])
        XCTAssertEqual(e.insights().today.completed, 0)
        XCTAssertEqual(e.insights().lastSeven.first { $0.day == past.day }?.completed, 1)
        XCTAssertTrue(e.planner.repeatOccurrences.isEmpty, "completing history must not create a repeat")
        let persisted = try PlannerFile.decoder.decode(Planner.self, from: PlannerFile.encoder.encode(e.planner))
        XCTAssertEqual(persisted, e.planner)
    }

    func testCompleteOverdueIgnoresIneligibleUnknownDuplicateAndHandledIDs() {
        let past = PlanTask(title: "Past", day: "2026-11-08")
        let dismissed = PlanTask(title: "Dismissed", day: "2026-11-08")
        let today = PlanTask(title: "Today", day: "2026-11-09")
        let future = PlanTask(title: "Future", day: "2026-11-10")
        let inbox = PlanTask(title: "Inbox", day: nil)
        let done = PlanTask(title: "Done", day: "2026-11-08", done: true, completedAt: Fixture.date("2026-11-08 17:00"))
        var e = engine([past, dismissed, today, future, inbox, done])
        e.dismissOverdue([dismissed.id])
        let originalOthers = Array(e.planner.tasks.dropFirst())
        XCTAssertEqual(
            e.completeOverdue([UUID(), past.id, today.id, inbox.id, dismissed.id, future.id, done.id, past.id]).count, 1
        )
        XCTAssertEqual(Array(e.planner.tasks.dropFirst()), originalOthers)
        let before = e.planner
        e.now = { Fixture.now.addingTimeInterval(10) }
        XCTAssertTrue(e.completeOverdue([past.id]).isEmpty)
        XCTAssertEqual(e.planner, before)
    }

    func testCompleteOverdueBanksRunningFocusBeforeMarkingDone() throws {
        let past = PlanTask(title: "Worked overnight", day: "2026-11-08", focusedSeconds: 30)
        var e = engine([past])
        e.planner.focus = FocusSession(taskID: past.id, limit: nil, now: Fixture.now.addingTimeInterval(-60))
        let finished = try XCTUnwrap(e.completeOverdue([past.id]).first)
        XCTAssertNil(e.planner.focus)
        XCTAssertEqual(finished.focusedSeconds, 90)
        XCTAssertTrue(finished.done)
        XCTAssertEqual(e.planner.focusLog.reduce(0) { $0 + $1.seconds }, 60)
    }

    func testCompleteOverdueRespectsResetHourAndDoesNotRelaxNormalEdits() throws {
        let current = PlanTask(title: "Current", day: "2026-11-09")
        let old = PlanTask(title: "Old", day: "2026-11-08")
        var e = engine([old, current], at: Fixture.date("2026-11-10 02:00"), resetHour: 4)
        XCTAssertThrowsError(try e.complete(old.id))
        XCTAssertThrowsError(try e.rename(old.id, on: .day(old.day!), to: "No"))
        XCTAssertEqual(e.completeOverdue([old.id, current.id]).map(\.id), [old.id])
        XCTAssertFalse(e.planner.tasks[1].done)
    }
}
