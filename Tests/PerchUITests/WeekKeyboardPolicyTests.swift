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
