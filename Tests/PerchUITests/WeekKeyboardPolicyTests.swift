import Foundation
import XCTest
@testable import PerchUI
@testable import PlannerCore

final class WeekKeyboardPolicyTests: XCTestCase {
    private let today: DayKey = "2027-01-15"
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testTaskFocusSelectsThatExactRowInsteadOfItsNeighbor() {
        let day = today.adding(days: 1, calendar: calendar)
        let first = PlanTask(title: "First", day: day)
        let second = PlanTask(title: "Second", day: day)
        let tasks = [first, second]
        assertMove(push(.task(second.id), from: day, tasks: tasks), id: second.id, to: "2027-01-17")
        assertMove(push(.task(first.id), from: day, tasks: tasks), id: first.id, to: "2027-01-17")
    }

    func testOnlyDirectColumnFocusMayChooseTheFirstTask() {
        let task = PlanTask(title: "Task", day: today)
        assertMove(push(.day(today), from: today, tasks: [task]), id: task.id, to: "2027-01-16")
        XCTAssertNil(push(nil, from: today, tasks: [task]))
        XCTAssertNil(push(.other, from: today, tasks: [task]))
        XCTAssertNil(push(.day("2027-01-16"), from: today, tasks: [task]))
    }

    func testMissingOrMovedFocusedTaskNeverFallsBackToAnotherRow() {
        let task = PlanTask(title: "Remaining", day: today)
        let elsewhere = PlanTask(title: "Moved", day: "2027-01-16")
        XCTAssertNil(push(.task(UUID()), from: today, tasks: [task]))
        XCTAssertNil(push(.task(elsewhere.id), from: today, tasks: [task, elsewhere]))
        XCTAssertNil(push(.day(today), from: today, tasks: []))
    }

    func testPastDoneAndUnscheduledTasksCannotBePushedByFocus() {
        let past = PlanTask(title: "Past", day: "2027-01-14")
        let done = PlanTask(title: "Done", day: today, done: true)
        let unscheduled = PlanTask(title: "Unscheduled", day: nil)
        let tasks = [past, done, unscheduled]
        XCTAssertNil(push(.task(past.id), from: "2027-01-14", tasks: tasks))
        XCTAssertNil(push(.day("2027-01-14"), from: "2027-01-14", tasks: tasks))
        XCTAssertNil(push(.task(done.id), from: today, tasks: tasks))
        XCTAssertNil(push(.task(unscheduled.id), from: today, tasks: tasks))
        XCTAssertNil(push(.day(today), from: today, tasks: tasks))
    }

    func testCheckboxFocusPushesTheExactTask() {
        let day = today.adding(days: 1, calendar: calendar)
        let first = PlanTask(title: "Same title", day: day)
        let second = PlanTask(title: first.title, day: day)
        assertMove(push(.checkbox(second.id), from: day, tasks: [first, second]), id: second.id, to: "2027-01-17")
        XCTAssertNil(push(.checkbox(UUID()), from: day, tasks: [first, second]))
        XCTAssertNil(push(.checkbox(second.id), from: today, tasks: [first, second]))
    }

    func testCheckboxSpaceChecksAndReopensOnlyItsTaskOnTodayAndComingDays() throws {
        for day in [today, today.adding(days: 1, calendar: calendar)] {
            let first = PlanTask(title: "Same title", day: day)
            let second = PlanTask(title: first.title, day: day)
            var planner = Planner(); planner.tasks = [first, second]
            var engine = PlannerEngine(
                planner: planner, now: { self.today.start(resetHour: 4, calendar: self.calendar) }, calendar: calendar)
            for done in [true, false] {
                let action = try XCTUnwrap(
                    completion(.checkbox(second.id), from: day, tasks: engine.planner.tasks))
                guard case .setScheduledCompletion(let id, let expectedDay, let completed) = action else {
                    return XCTFail("Week Space must use the date-bound completion command")
                }
                XCTAssertEqual(id, second.id)
                XCTAssertEqual(expectedDay, day)
                XCTAssertEqual(completed, done)
                try engine.execute(action)
                XCTAssertEqual(try engine.task(second.id).done, done)
                XCTAssertFalse(try engine.task(first.id).done)
            }
        }
    }

    func testSpaceDoesNotCompleteFromMenuColumnFieldOrMissingFocus() {
        let task = PlanTask(title: "Task", day: today)
        for focus: WeekTaskPolicy.KeyboardFocus? in [nil, .task(task.id), .day(today), .other] {
            XCTAssertNil(completion(focus, from: today, tasks: [task]))
        }
    }

    func testSpaceRejectsMissingMovedPastAndUnscheduledCheckboxTasks() {
        let day = today.adding(days: 1, calendar: calendar)
        let future = PlanTask(title: "Future", day: day)
        let past = PlanTask(title: "Past", day: "2027-01-14")
        let inbox = PlanTask(title: "Inbox", day: nil)
        let tasks = [future, past, inbox]
        XCTAssertNil(completion(.checkbox(UUID()), from: day, tasks: tasks))
        XCTAssertNil(completion(.checkbox(future.id), from: today, tasks: tasks))
        XCTAssertNil(completion(.checkbox(past.id), from: past.day!, tasks: tasks))
        XCTAssertNil(completion(.checkbox(inbox.id), from: day, tasks: tasks))
    }

    private func completion(
        _ focus: WeekTaskPolicy.KeyboardFocus?, from day: DayKey, tasks: [PlanTask]
    ) -> PlannerAction? {
        WeekTaskPolicy.completionAction(focus: focus, from: day, tasks: tasks, today: today)
    }

    private func assertMove(
        _ action: PlannerAction?, id: UUID, to day: DayKey, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .move(let actualID, let destination) = action else {
            XCTFail("Expected a move action", file: file, line: line)
            return
        }
        XCTAssertEqual(actualID, id, file: file, line: line)
        XCTAssertEqual(destination.key, day, file: file, line: line)
    }

    private func push(
        _ focus: WeekTaskPolicy.KeyboardFocus?, from day: DayKey, tasks: [PlanTask]
    ) -> PlannerAction? {
        WeekTaskPolicy.pushAction(focus: focus, from: day, tasks: tasks, today: today, calendar: calendar)
    }
}
