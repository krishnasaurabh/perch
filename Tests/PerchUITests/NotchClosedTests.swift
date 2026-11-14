import Foundation
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import XCTest
@testable import PerchUI
@testable import PlannerCore

final class NotchClosedTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let housing = CGRect(x: -849, y: 950, width: 185, height: 32)

    func testProgressGeometryUsesHousingEdgesAndRemainingFraction() {
        let line = NotchLayout.progressLine(housing: housing)
        XCTAssertEqual(line, CGRect(x: -837, y: 947, width: 161, height: 3))
        XCTAssertEqual(NotchLayout.progressFill(line: line, fraction: 0.25).width, 40.25)
        XCTAssertEqual(NotchLayout.progressFill(line: line, fraction: -1).width, 0)
        XCTAssertEqual(NotchLayout.progressFill(line: line, fraction: 2).width, line.width)
        XCTAssertEqual(NotchLayout.progressFill(line: line, fraction: .nan).width, 0)
        XCTAssertEqual(NotchLayout.progressLine(housing: CGRect(x: 0, y: 0, width: 10, height: 32)).width, 0)
    }

    func testTabIsBelowVisibleMenuBarOnAllFlatDisplays() {
        for builtIn in [true, false] {
            let screen = NotchLayout.Screen(
                frame: CGRect(x: -1920, y: 100, width: 1920, height: 1080),
                visibleFrame: CGRect(x: -1920, y: 100, width: 1920, height: 1055), isBuiltIn: builtIn)
            let tab = NotchLayout.closedTab(screen: screen)
            XCTAssertEqual(tab.height, 22)
            XCTAssertEqual(tab.width, 76)
            XCTAssertEqual(tab.midX, screen.frame.midX)
            XCTAssertEqual(tab.maxY, screen.visibleFrame.maxY)
            XCTAssertTrue(screen.frame.contains(tab))
            var hiddenMenu = screen
            hiddenMenu.visibleFrame = hiddenMenu.frame
            XCTAssertEqual(NotchLayout.closedTab(screen: hiddenMenu).maxY, hiddenMenu.frame.maxY)
        }
    }

    func testReminderIsEightPointCircleCenteredBelowHousing() {
        let dot = NotchLayout.reminderDot(housing: housing, progressVisible: false)
        XCTAssertEqual(dot.size, CGSize(width: 8, height: 8))
        XCTAssertEqual(dot.midX, housing.midX)
        XCTAssertLessThan(dot.maxY, housing.minY)
        let withLine = NotchLayout.reminderDot(housing: housing, progressVisible: true)
        XCTAssertLessThan(withLine.maxY, NotchLayout.progressLine(housing: housing).minY)
    }

    func testActivationPreservesDoubleClickAndKeyboardRoutes() {
        XCTAssertFalse(NotchClosedPresentation.allowsActivation(trigger: .doubleClick, clickCount: 1))
        XCTAssertTrue(NotchClosedPresentation.allowsActivation(trigger: .doubleClick, clickCount: 2))
        XCTAssertTrue(NotchClosedPresentation.allowsActivation(trigger: .doubleClick, clickCount: nil))
        XCTAssertTrue(NotchClosedPresentation.allowsActivation(trigger: .click, clickCount: 1))
        XCTAssertTrue(NotchClosedPresentation.allowsActivation(trigger: .hover, clickCount: 1))
    }

    func testIdleAndFinishedBlocksHaveNoIndicator() {
        var planner = Planner()
        XCTAssertFalse(NotchClosedPresentation(planner: planner).isVisible)
        planner.focus = FocusSession(taskID: nil, limit: 60, now: now)
        planner.focus?.state = .finished
        XCTAssertFalse(NotchClosedPresentation(planner: planner).isVisible)
    }

    func testRunningLineShortensAndPauseFreezesRemainingTime() {
        var planner = Planner()
        planner.focus = FocusSession(taskID: nil, limit: 600, now: now)
        let running = NotchClosedPresentation(planner: planner)
        XCTAssertEqual(running.line, .running)
        XCTAssertEqual(running.fraction(at: now), 1)
        XCTAssertEqual(running.fraction(at: now.addingTimeInterval(150)), 0.75)
        XCTAssertEqual(running.fraction(at: now.addingTimeInterval(900)), 0)
        planner.focus?.state = .paused
        planner.focus?.banked = 150
        planner.focus?.resumedAt = nil
        let paused = NotchClosedPresentation(planner: planner)
        XCTAssertEqual(paused.line, .paused)
        XCTAssertEqual(paused.fraction(at: now.addingTimeInterval(900)), 0.75)
    }

    func testIndependentPreferencesAndReminderPersistence() {
        var planner = Planner()
        planner.focus = FocusSession(taskID: nil, limit: 600, now: now)
        planner.preferences.notchProgressLine = false
        var state = NotchClosedPresentation(planner: planner, reminderWaiting: true)
        XCTAssertEqual(state.line, .none)
        XCTAssertTrue(state.reminder)
        XCTAssertTrue(state.isVisible)
        XCTAssertTrue(state.hasBlock, "Flat-screen time remains useful with the progress line disabled")
        planner.preferences.notchReminderDot = false
        state = NotchClosedPresentation(planner: planner, reminderWaiting: true)
        XCTAssertFalse(state.reminder)
        XCTAssertFalse(state.isVisible)
        planner.preferences.notchProgressLine = true
        state = NotchClosedPresentation(planner: planner, reminderWaiting: true)
        XCTAssertEqual(state.line, .running)
        XCTAssertFalse(state.reminder)
        planner.focus = nil
        planner.preferences.notchReminderDot = true
        XCTAssertTrue(NotchClosedPresentation(planner: planner, reminderWaiting: true).reminder)
        XCTAssertFalse(NotchClosedPresentation(planner: planner, reminderWaiting: false).reminder)
    }

    func testUnboundedBlockHasTimeButDoesNotPretendToHaveRemainingProgress() {
        var planner = Planner()
        planner.focus = FocusSession(taskID: nil, limit: nil, now: now)
        let state = NotchClosedPresentation(planner: planner)
        XCTAssertEqual(state.line, .none)
        XCTAssertTrue(state.hasBlock)
        XCTAssertEqual(state.fraction(at: now), 0)
    }

    func testClockRunsForFlatReminderButNotIdleOrPausedCountdowns() {
        var planner = Planner()
        for hardware in [true, false] {
            XCTAssertFalse(NotchClosedPresentation(planner: planner).needsClock(hasHardwareNotch: hardware))
            XCTAssertEqual(
                NotchClosedPresentation(planner: planner, reminderWaiting: true)
                    .needsClock(hasHardwareNotch: hardware), !hardware)
        }
        planner.preferences.notchReminderDot = false
        XCTAssertFalse(
            NotchClosedPresentation(planner: planner, reminderWaiting: true).needsClock(hasHardwareNotch: false))
        planner.preferences.notchReminderDot = true
        planner.focus = FocusSession(taskID: nil, limit: 600, now: now)
        for hardware in [true, false] {
            XCTAssertTrue(NotchClosedPresentation(planner: planner).needsClock(hasHardwareNotch: hardware))
            planner.preferences.notchProgressLine = false
            XCTAssertTrue(NotchClosedPresentation(planner: planner).needsClock(hasHardwareNotch: hardware))
            planner.preferences.notchProgressLine = true
        }
        planner.focus?.state = .paused
        planner.focus?.resumedAt = nil
        for hardware in [true, false] {
            XCTAssertFalse(
                NotchClosedPresentation(planner: planner, reminderWaiting: true)
                    .needsClock(hasHardwareNotch: hardware))
        }
        planner.focus?.state = .finished
        XCTAssertTrue(
            NotchClosedPresentation(planner: planner, reminderWaiting: true).needsClock(hasHardwareNotch: false))
    }

    func testReminderOnlyTimeCrossesMinuteBoundaryWithoutPlannerMutation() {
        let planner = Planner()
        let original = planner
        let reminder = NotchClosedPresentation(planner: planner, reminderWaiting: true)
        let locale = Locale(identifier: "en_US_POSIX")
        let before = now.addingTimeInterval(59)
        let after = before.addingTimeInterval(1)
        XCTAssertTrue(reminder.needsClock(hasHardwareNotch: false))
        XCTAssertNotEqual(reminder.timeText(at: before, locale: locale), reminder.timeText(at: after, locale: locale))
        XCTAssertEqual(
            reminder.timeText(at: after, locale: locale),
            after.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)))
        XCTAssertEqual(planner, original)
    }

    func testClosedTokensMeetSignalContrastOnPermanentBlackSurface() {
        func luminance(_ hex: UInt32) -> Double {
            let channels = [16, 8, 0].map { shift -> Double in
                let value = Double((hex >> shift) & 255) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        let background = luminance(NotchClosedTokens.background)
        for color in [NotchClosedTokens.fill, NotchClosedTokens.paused, NotchClosedTokens.reminder] {
            XCTAssertGreaterThanOrEqual((luminance(color) + 0.05) / (background + 0.05), 3)
        }
        XCTAssertGreaterThanOrEqual((luminance(NotchClosedTokens.text) + 0.05) / (background + 0.05), 4.5)
        XCTAssertEqual(DesignTokens.MotionToken.time.duration, 0.65)
        XCTAssertFalse(DesignTokens.MotionToken.time.plan(reduceMotion: true).allowsSpatialMotion)
        XCTAssertEqual(DesignTokens.MotionToken.time.plan(reduceMotion: true).duration, 0.12)
    }
}
