import Foundation
import PerchUI
import PlannerCore
import XCTest

final class NotchPresentationTests: XCTestCase {
    func testLongClockCannotOverflowCapsuleInnerWidth() {
        let text = "1000000:00:00"
        let dot = NotchTimerPresentation.dot(for: text, width: 52, height: 12)
        XCTAssertLessThanOrEqual(NotchTimerPresentation.units(for: text) * dot, 52)
    }

    func testTimerFaceKeepsFullPrecisionAndBoundsItsVisibleText() {
        let cases: [(Double, String, Bool)] = [
            (0, "00:00", true), (754, "12:34", true), (3599, "59:59", true),
            (3600, "1:00:00", true), (359999, "99:59:59", true),
            (360000, "100h", false), (3_600_000_000, "41666d", false),
            (999_999_999_999, "31709y", false),
        ]
        for (seconds, expected, matrix) in cases {
            let face = NotchTimerPresentation(seconds: seconds)
            XCTAssertEqual(face.text, expected)
            XCTAssertEqual(face.fullText, TimerText.clock(seconds))
            XCTAssertEqual(face.usesDotMatrix, matrix)
            XCTAssertLessThanOrEqual(face.text.count, 8)
            if matrix {
                for height in [CGFloat(16), 23, 27] {
                    let dot = NotchTimerPresentation.dot(for: face.text, width: 60, height: height * 0.68)
                    XCTAssertGreaterThanOrEqual(dot, 1.5, "Readable dots even on the shortest housing")
                    XCTAssertLessThanOrEqual(NotchTimerPresentation.units(for: face.text) * dot, 60.001)
                    XCTAssertLessThanOrEqual(dot * 6.8, height * 0.68 + 0.001)
                }
            }
        }
    }

    func testInvalidTimerDoesNotTrapOrRenderInventedTime() {
        for seconds in [Double.nan, .infinity, -.infinity, -1, 1_000_000_000_000] {
            let face = NotchTimerPresentation(seconds: seconds)
            XCTAssertEqual(face.text, "--:--")
            XCTAssertFalse(face.usesDotMatrix)
            XCTAssertEqual(face.fullText, "Timer unavailable")
        }
    }

    func testMissedRequiresOwnersExactCurrentOccurrence() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var task = PlanTask(title: "Synthetic reminder", day: "2027-01-15", remindAt: now.addingTimeInterval(-5))
        let id = ScheduledReminder(task: task).id
        let due = task.remindAt!
        for state in [ReminderRecord.State.scheduled, .delivered, .missed] {
            let records = [id: ReminderRecord(date: due, state: state)]
            XCTAssertEqual(NotchReminderPresentation.isMissed(task: task, records: records, now: now), state == .missed)
        }
        XCTAssertFalse(NotchReminderPresentation.isMissed(task: task, records: [:], now: now))
        XCTAssertFalse(
            NotchReminderPresentation.isMissed(
                task: task, records: [id: .init(date: now, state: .missed)], now: now))
        let history = [id: ReminderRecord(date: due, state: .missed)]
        task.remindAt = now.addingTimeInterval(300)
        XCTAssertFalse(NotchReminderPresentation.isMissed(task: task, records: history, now: now))
        task.remindAt = due; task.done = true
        XCTAssertFalse(NotchReminderPresentation.isMissed(task: task, records: history, now: now))
        task.done = false; task.day = nil
        XCTAssertFalse(NotchReminderPresentation.isMissed(task: task, records: history, now: now))
        XCTAssertFalse(NotchReminderPresentation.isMissed(task: nil, records: history, now: now))
    }

    func testClosedTriggerDoesNotIncludeMenuItemsOrTimerGap() {
        for (_, screen) in Screens.all {
            let workspace = WorkspaceLayout.frame(screen: screen)
            let target = NotchLayout.triggerFrame(workspace: workspace, expanded: false, screen: screen)
            XCTAssertEqual(target, NotchLayout.notch(screen: screen))
            XCTAssertFalse(NotchLayout.contains(target, pointer: CGPoint(x: target.maxX + 3, y: target.midY)))
            XCTAssertFalse(NotchLayout.contains(target, pointer: CGPoint(x: target.minX - 3, y: target.midY)))
            XCTAssertFalse(NotchLayout.contains(target, pointer: CGPoint(x: target.midX, y: target.minY - 1)))
            XCTAssertEqual(NotchLayout.triggerFrame(workspace: workspace, expanded: true, screen: screen), workspace)
        }
    }

    func testCapsuleTransparentCornersAreClickThroughAtBothScales() {
        for scale in [CGFloat(1), 2] {
            let rect = CGRect(x: -100, y: 950, width: 76, height: 23)
            XCTAssertTrue(NotchLayout.capsuleContains(rect, pointer: CGPoint(x: rect.midX, y: rect.midY)))
            XCTAssertTrue(NotchLayout.capsuleContains(rect, pointer: CGPoint(x: rect.minX + 1 / scale, y: rect.midY)))
            XCTAssertFalse(
                NotchLayout.capsuleContains(rect, pointer: CGPoint(x: rect.minX + 1 / scale, y: rect.maxY - 1 / scale)))
            XCTAssertFalse(
                NotchLayout.capsuleContains(rect, pointer: CGPoint(x: rect.maxX - 1 / scale, y: rect.minY + 1 / scale)))
            XCTAssertFalse(NotchLayout.capsuleContains(rect, pointer: CGPoint(x: rect.midX, y: rect.minY - 1 / scale)))
        }
    }

    func testDwellRequiresOneUninterruptedVisit() throws {
        var intent = NotchHoverIntent()
        let first = try XCTUnwrap(intent.enter(screen: 1))
        XCTAssertNil(intent.enter(screen: 1))
        _ = intent.enter(screen: nil)
        let next = try XCTUnwrap(intent.enter(screen: 1))
        XCTAssertFalse(intent.consume(first, screen: 1, eligible: true))
        XCTAssertTrue(intent.consume(next, screen: 1, eligible: true))
        XCTAssertFalse(intent.consume(next, screen: 1, eligible: true))
    }

    func testDwellRevalidatesFullscreenSettingsAndScreen() throws {
        var intent = NotchHoverIntent()
        let first = try XCTUnwrap(intent.enter(screen: 1))
        let second = try XCTUnwrap(intent.enter(screen: 2))
        XCTAssertFalse(intent.consume(first, screen: 1, eligible: true))
        XCTAssertFalse(intent.consume(second, screen: 2, eligible: false))
        let next = try XCTUnwrap(intent.enter(screen: 2))
        intent.cancel()
        XCTAssertFalse(intent.consume(next, screen: 2, eligible: true))
    }

    func testDismissMustLeaveBeforeReopeningButOtherScreenCanOpen() throws {
        var intent = NotchHoverIntent()
        let first = try XCTUnwrap(intent.enter(screen: 1))
        intent.cancel(blocking: 1)
        XCTAssertFalse(intent.consume(first, screen: 1, eligible: true))
        XCTAssertNil(intent.enter(screen: 1))
        _ = intent.enter(screen: nil)
        XCTAssertNotNil(intent.enter(screen: 1))
        intent.cancel(blocking: 1)
        XCTAssertNotNil(intent.enter(screen: 2))
    }
}
