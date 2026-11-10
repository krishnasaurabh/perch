import XCTest
@testable import PlannerCore
@testable import PerchUI

final class HomeLayoutTests: XCTestCase {
    func testFreshInstallShowsOnlyTasksWhenIdle() {
        let p = Preferences()
        XCTAssertFalse(p.workspaceCardOrder.contains("insights"))
        XCTAssertEqual(HomeLayout.sideCards(p, timerActive: false, hasEvents: false), [])
    }

    func testTimerAndAgendaAppearOnlyWhenTheyMatter() {
        let p = Preferences()
        XCTAssertEqual(HomeLayout.sideCards(p, timerActive: true, hasEvents: false), ["focus"])
        XCTAssertEqual(HomeLayout.sideCards(p, timerActive: false, hasEvents: true), ["events"])
        XCTAssertEqual(HomeLayout.sideCards(p, timerActive: true, hasEvents: true), ["focus", "events"])
    }

    func testNotepadIsOptIn() {
        var p = Preferences()
        XCTAssertTrue(p.hiddenWorkspaceCards.contains("notepad"))
        p.hiddenWorkspaceCards = []
        XCTAssertEqual(HomeLayout.sideCards(p, timerActive: false, hasEvents: false), ["notepad"])
    }

    func testLegacyOrderWithInsightsNeverPutsInsightsOnToday() {
        // A planner.json saved before Insights moved to its own tab.
        let order = ["insights", "events", "tasks", "notepad", "focus"]
        let side = HomeLayout.sideCards(order: order, hidden: [], timerActive: true, hasEvents: true)
        XCTAssertEqual(side, ["events", "notepad", "focus"])
    }

    func testHiddenCardsStayHiddenEvenWhenActive() {
        let side = HomeLayout.sideCards(
            order: ["focus", "events"], hidden: ["focus", "events", "notepad"], timerActive: true, hasEvents: true)
        XCTAssertEqual(side, [])
        // An order that omits the notepad still honours its visibility: missing ids are appended, not hidden.
        XCTAssertEqual(
            HomeLayout.sideCards(order: ["focus"], hidden: [], timerActive: false, hasEvents: false), ["notepad"])
    }

    func testCardsMissingFromAnOldOrderFollowPlacedOnes() {
        XCTAssertEqual(HomeLayout.ordered(["events"]), ["events", "focus", "notepad"])
        XCTAssertEqual(HomeLayout.ordered(["focus", "tasks"]), ["focus", "events", "notepad"])
    }

    func testUnknownAndDuplicateIdsAreIgnored() {
        XCTAssertEqual(
            HomeLayout.ordered(["focus", "bogus", "focus", "tasks", "insights"]), ["focus", "events", "notepad"])
    }

    func testLegacyPreferencesDecodeKeepTheirSavedChoices() throws {
        let json = #"{"workspaceCardOrder":["tasks","focus","notepad","events","insights"],"hiddenWorkspaceCards":[]}"#
        let p = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        // Someone who had the notepad on keeps it on; insights is simply never drawn on Today.
        XCTAssertEqual(HomeLayout.sideCards(p, timerActive: false, hasEvents: false), ["notepad"])
        XCTAssertEqual(HomeLayout.sideCards(p, timerActive: true, hasEvents: true), ["focus", "notepad", "events"])
    }
}
