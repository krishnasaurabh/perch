import Foundation
import PlannerCore
import XCTest
@testable import PerchUI

final class HistoryModelTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        return value
    }
    private func engine(_ tasks: [PlanTask]) -> PlannerEngine {
        var planner = Planner()
        planner.tasks = tasks
        let now = DayKey("2026-11-13").date(calendar: calendar).addingTimeInterval(12 * 3600)
        return PlannerEngine(planner: planner, now: { now }, calendar: calendar)
    }

    func testOnlyFinishedTasksAreGroupedNewestFirstIncludingToday() {
        let tasks = [
            PlanTask(title: "Open", day: "2026-11-12"),
            PlanTask(title: "Yesterday", day: "2026-11-12", done: true),
            PlanTask(title: "Today", day: "2026-11-13", done: true),
            PlanTask(title: "Older", day: "2026-11-11", done: true),
        ]
        let model = HistoryModel(engine: engine(tasks))
        XCTAssertEqual(model.groups.map(\.day), ["2026-11-13", "2026-11-12", "2026-11-11"])
        XCTAssertEqual(model.groups.flatMap(\.tasks).map(\.title), ["Today", "Yesterday", "Older"])
        XCTAssertEqual(model.groups.map(\.initiallyExpanded), [true, true, false])
        XCTAssertEqual(model.weekDone, 3)
        XCTAssertEqual(model.weekActiveDays, 3)
    }

    func testFourFiltersUseExactMetadataNotInferredLabels() {
        let plain = PlanTask(title: "Plain", day: "2026-11-12", done: true)
        var carried = plain; carried.id = UUID(); carried.carryCount = 1
        var focused = plain; focused.id = UUID(); focused.focusedSeconds = 1
        var scheduled = plain; scheduled.id = UUID(); scheduled.startAt = Date()
        var agent = plain; agent.id = UUID(); agent.agentID = "claude-code"
        var planned = plain; planned.id = UUID(); planned.minutes = 30
        let source = engine([plain, carried, focused, scheduled, agent, planned])
        func ids(_ filter: HistoryModel.Filter) -> [UUID] {
            HistoryModel(engine: source, filter: filter).groups.flatMap(\.tasks).map(\.id)
        }
        XCTAssertEqual(ids(.everything).count, 6)
        XCTAssertEqual(ids(.carried), [carried.id])
        XCTAssertEqual(ids(.time), [focused.id, scheduled.id])
        XCTAssertEqual(ids(.agent), [agent.id])
        XCTAssertEqual(HistoryModel.Filter.allCases.count, 4)
    }

    func testSearchCombinesWithFilterAndIgnoresCaseDiacriticsAndSurroundingWhitespace() {
        let source = engine([
            PlanTask(title: "Café receipts", day: "2026-11-12", done: true, carryCount: 1),
            PlanTask(title: "Cafe receipt book", day: "2026-11-12", done: true),
            PlanTask(title: "Unrelated", day: "2026-11-11", done: true, carryCount: 1),
        ])
        let model = HistoryModel(engine: source, query: "  CAFE  ", filter: .carried)
        XCTAssertEqual(model.groups.flatMap(\.tasks).map(\.title), ["Café receipts"])
        XCTAssertEqual(model.weekDone, 3, "The week summary never changes with search or filtering")
        XCTAssertTrue(HistoryModel(engine: source, query: "missing").groups.isEmpty)
    }

    func testBlockDetailUsesRecordedMinutesRatherThanThePlannedLimit() {
        var task = PlanTask(title: "Short block", day: "2026-11-13", done: true, minutes: 60)
        XCTAssertNil(HistoryModel.recordedBlockMinutes(task))
        task.focusedSeconds = 5 * 60
        XCTAssertEqual(HistoryModel.recordedBlockMinutes(task), 5)
        task.focusedSeconds = 20
        XCTAssertEqual(HistoryModel.recordedBlockMinutes(task), 0)
    }

    func testActualCompletionDayAndLegacyDayAreBothRetained() {
        let completion = DayKey("2026-11-13").date(calendar: calendar).addingTimeInterval(3600)
        let source = engine([
            PlanTask(title: "Late night", day: "2026-11-11", done: true, completedAt: completion),
            PlanTask(title: "Legacy", day: "2026-11-10", done: true),
            PlanTask(title: "Inbox finished", day: nil, done: true, completedAt: completion),
            PlanTask(title: "Undated legacy", day: nil, done: true),
        ])
        let model = HistoryModel(engine: source)
        XCTAssertEqual(model.groups.map(\.day), ["2026-11-12", "2026-11-10"])
        XCTAssertEqual(model.groups.first?.tasks.map(\.title), ["Late night", "Inbox finished"])
        XCTAssertEqual(model.undated.map(\.title), ["Undated legacy"])
    }
}
