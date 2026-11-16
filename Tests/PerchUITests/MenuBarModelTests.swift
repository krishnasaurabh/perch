import Foundation
import PlannerCore
import PerchUI
import XCTest

final class MenuBarModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today: DayKey = "2026-11-13"

    func testFixedBlackPillHasReadableRunningAndPausedInk() {
        func luminance(_ hex: UInt32) -> Double {
            let channels = [hex >> 16, hex >> 8, hex].map { Double($0 & 255) / 255 }
            let linear = channels.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        let background = luminance(MenuBarTokens.background)
        for ink in [MenuBarTokens.ink, MenuBarTokens.pausedInk] {
            XCTAssertGreaterThanOrEqual((luminance(ink) + 0.05) / (background + 0.05), 4.5)
        }
        XCTAssertGreaterThanOrEqual((luminance(MenuBarTokens.dot) + 0.05) / (background + 0.05), 3)
        XCTAssertEqual(MenuBarTokens.height, 22)
    }

    func testIdleMenuOrderAndEnabledStates() {
        let model = MenuBarModel(planner: Planner(), today: today, now: now)
        XCTAssertEqual(
            model.entries, [.addTask, .openToday, .openWeek, .separator, .privacy, .separator, .settings, .quit])
        XCTAssertNil(model.block)
        XCTAssertFalse(model.isEnabled(.pauseOrContinue))
        XCTAssertFalse(model.isEnabled(.addFiveMinutes))
        for action in [MenuBarModel.Action.addTask, .openToday, .openWeek, .privacy, .settings, .quit] {
            XCTAssertTrue(model.isEnabled(action))
        }
        XCTAssertEqual(model.item.text, nil)
        XCTAssertFalse(model.item.isPill)
        XCTAssertTrue(model.item.isVisible)
    }

    func testRunningMenuLeadsWithTheBlockAndItsControls() throws {
        let model = make()
        XCTAssertEqual(
            model.entries,
            [
                .runningBlock, .separator, .addTask, .openToday, .openWeek, .separator, .privacy, .separator, .settings,
                .quit,
            ])
        let block = try XCTUnwrap(model.block)
        XCTAssertEqual(block.title, "Write the checklist")
        XCTAssertEqual(block.detail, "24:10 left · 2 of 4 steps")
        XCTAssertEqual(block.pauseTitle, "Pause")
        XCTAssertTrue(model.isEnabled(.pauseOrContinue))
        XCTAssertTrue(model.isEnabled(.addFiveMinutes))
        XCTAssertEqual(model.item.text, "24:10")
        XCTAssertTrue(model.item.showsDot)
        XCTAssertTrue(model.item.isPill)
        XCTAssertFalse(model.item.isDimmed)
        XCTAssertTrue(model.needsClock(menuOpen: false))
    }

    func testEveryModeAndZeroTasks() {
        for mode in MenuBarDisplay.allCases {
            let model = make(mode: mode)
            XCTAssertEqual(model.item.isVisible, mode != .hidden)
            switch mode {
            case .icon:
                XCTAssertFalse(model.item.isPill)
                XCTAssertNil(model.item.text)
                XCTAssertFalse(model.item.showsDot)
            case .timeLeft: XCTAssertEqual(model.item.text, "24:10")
            case .tasksLeft: XCTAssertEqual(model.item.text, "6 left")
            case .hidden: XCTAssertNil(model.item.text)
            }
        }
        var planner = Planner()
        planner.preferences.hideCountsAndTimes = false
        planner.preferences.menuBarDisplay = .tasksLeft
        XCTAssertEqual(MenuBarModel(planner: planner, today: today, now: now).item.text, "0 left")
    }

    func testPausedHasNoDotAndDimDigitsAndContinue() {
        let model = make(paused: true)
        XCTAssertFalse(model.item.showsDot)
        XCTAssertTrue(model.item.isDimmed)
        XCTAssertEqual(model.item.text, "24:10")
        XCTAssertEqual(model.block?.pauseTitle, "Continue")
        XCTAssertFalse(model.needsClock(menuOpen: true))
    }

    func testPrivacyRemovesCountsAndTimesFromAllProjectedStrings() throws {
        for mode in [MenuBarDisplay.icon, .timeLeft, .tasksLeft] {
            let model = make(mode: mode, privacy: true)
            XCTAssertNil(model.item.text)
            XCTAssertTrue(model.item.showsDot)
            XCTAssertTrue(model.item.isPill)
            XCTAssertTrue(model.privacyEnabled)
            let block = try XCTUnwrap(model.block)
            for text in [model.item.accessibilityLabel, block.detail] {
                XCTAssertFalse(text.contains("24:10"))
                XCTAssertFalse(text.contains("6"))
                XCTAssertFalse(text.contains("2 of 4"))
            }
            XCTAssertFalse(model.needsClock(menuOpen: true))
        }
        XCTAssertFalse(make(paused: true, privacy: true).item.showsDot)
    }

    func testIdleTimeModeAndFinishedBlockUseOnlyTheTemplateMark() {
        var planner = fixture()
        planner.focus = nil
        let idle = MenuBarModel(planner: planner, today: today, now: now)
        XCTAssertFalse(idle.item.isPill)
        XCTAssertNil(idle.item.text)
        XCTAssertFalse(idle.item.showsDot)
        planner.focus = fixture().focus
        planner.focus?.state = .finished
        let finished = MenuBarModel(planner: planner, today: today, now: now)
        XCTAssertEqual(finished.item, idle.item)
        XCTAssertNil(finished.block)
    }

    func testCountExcludesDoneOtherDaysAndUnscheduledTasks() {
        var planner = fixture()
        planner.preferences.menuBarDisplay = .tasksLeft
        planner.tasks[0].done = true
        planner.tasks[1].day = today.adding(days: 1)
        planner.tasks[2].day = nil
        XCTAssertEqual(MenuBarModel(planner: planner, today: today, now: now).item.text, "3 left")
    }

    func testStopwatchIsElapsedAndCannotBeExtended() {
        var planner = fixture()
        planner.focus?.limit = nil
        let model = MenuBarModel(planner: planner, today: today, now: now)
        XCTAssertEqual(model.item.text, "20:50")
        XCTAssertEqual(model.block?.detail, "20:50 elapsed · 2 of 4 steps")
        XCTAssertFalse(model.isEnabled(.addFiveMinutes))
        XCTAssertTrue(model.isEnabled(.pauseOrContinue))
    }

    func testClockOnlyRunsForVisibleTimeOrAnOpenMenu() {
        XCTAssertFalse(make(mode: .icon).needsClock(menuOpen: false))
        XCTAssertTrue(make(mode: .icon).needsClock(menuOpen: true))
        XCTAssertFalse(make(mode: .tasksLeft).needsClock(menuOpen: false))
        XCTAssertFalse(make(mode: .hidden).needsClock(menuOpen: true))
        XCTAssertTrue(make().needsClock(menuOpen: false))
    }

    func testShortcutsUseReboundAddChordAndStandardCommands() {
        let model = make()
        XCTAssertEqual(model.shortcut(for: .addTask), .init(key: "n", modifiers: .option))
        XCTAssertEqual(model.shortcut(for: .settings), .init(key: ",", modifiers: .command))
        XCTAssertEqual(model.shortcut(for: .quit), .init(key: "q", modifiers: .command))
        XCTAssertEqual(model.shortcut(for: .pauseOrContinue), .init(key: "p", modifiers: .command))
        XCTAssertEqual(model.shortcut(for: .addFiveMinutes), .init(key: "+", modifiers: .command))
        let rebound = MenuBarModel(
            planner: fixture(), today: today, now: now,
            addShortcut: ShortcutKey(keyCode: 40, modifiers: [.control, .option]))
        XCTAssertEqual(rebound.shortcut(for: .addTask), .init(key: "k", modifiers: [.control, .option]))
    }

    func testSpecialSavedShortcutsUseNativeFunctionKeyCharacters() {
        for (code, character) in [
            (UInt32(96), "\u{F708}"), (115, "\u{F729}"), (117, "\u{F728}"), (116, "\u{F72C}"), (124, "\u{F703}"),
        ] {
            let model = MenuBarModel(
                planner: fixture(), today: today, now: now, addShortcut: .init(keyCode: code, modifiers: .control))
            XCTAssertEqual(model.shortcut(for: .addTask), .init(key: character, modifiers: .control))
        }
    }

    func testModelNeverMutatesPlannerAndClockAdvancesWithoutWrites() {
        let planner = fixture()
        let first = MenuBarModel(planner: planner, today: today, now: now)
        let later = MenuBarModel(planner: planner, today: today, now: now.addingTimeInterval(1))
        XCTAssertEqual(first.item.text, "24:10")
        XCTAssertEqual(later.item.text, "24:09")
        XCTAssertEqual(planner, fixture())
    }

    private func make(mode: MenuBarDisplay = .timeLeft, paused: Bool = false, privacy: Bool = false) -> MenuBarModel {
        var planner = fixture()
        planner.preferences.menuBarDisplay = mode
        planner.preferences.hideCountsAndTimes = privacy
        if paused { planner.focus?.state = .paused; planner.focus?.resumedAt = nil }
        return MenuBarModel(planner: planner, today: today, now: now)
    }

    private func fixture() -> Planner {
        var planner = Planner()
        planner.preferences.menuBarDisplay = .timeLeft
        planner.preferences.hideCountsAndTimes = false
        planner.tasks = (0..<6).map { index in
            PlanTask(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                title: "Write the checklist", day: today, createdAt: now,
                steps: (0..<4).map {
                    Subtask(
                        id: UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", $0 + 1))!, title: "Step",
                        done: $0 < 2)
                })
        }
        var focus = FocusSession(taskID: planner.tasks[0].id, limit: 45 * 60, now: now)
        focus.banked = 20 * 60 + 50
        planner.focus = focus
        return planner
    }
}
