import Foundation
import PlannerCore
import PerchUI
import XCTest

final class NotchPillLayoutTests: XCTestCase {
    private let today = DayKey("2026-11-13")
    private let now = Date(timeIntervalSince1970: 1_794_565_250)

    func testEveryPillIsOffByDefaultAndIndependent() {
        var planner = sample()
        XCTAssertTrue(pills(planner).isEmpty)
        planner.preferences.notchTimePill = true
        XCTAssertEqual(pills(planner).map(\.kind), [.time])
        planner.preferences.notchTimePill = false
        planner.preferences.notchTaskCount = true
        XCTAssertEqual(pills(planner).map(\.kind), [.tasks])
        planner.preferences.notchTaskCount = false
        planner.preferences.notchNextBlock = true
        XCTAssertEqual(pills(planner).map(\.kind), [.nextBlock])
    }

    func testTimeUsesFullClockAndPauseHasNoDotOrBlink() throws {
        var planner = sample()
        planner.preferences.notchTimePill = true
        var face = try XCTUnwrap(pills(planner).first)
        XCTAssertEqual(face.text, "24:10")
        XCTAssertTrue(face.showsDot)
        planner.focus?.limit = 7199
        face = try XCTUnwrap(pills(planner).first)
        XCTAssertEqual(face.text, "1:59:59")
        planner.focus?.state = .paused
        planner.focus?.resumedAt = nil
        face = try XCTUnwrap(pills(planner).first)
        XCTAssertFalse(face.showsDot)
        XCTAssertTrue(face.paused)
        XCTAssertEqual(face.ink, NotchPillLayout.pausedInk)
        XCTAssertEqual(pills(planner), pills(planner, at: now.addingTimeInterval(100)))
        planner.focus?.state = .finished
        XCTAssertTrue(pills(planner).isEmpty)
    }

    func testTaskCountCoexistsWithTimeAndNeverIncludesNamesOrOtherDays() throws {
        var planner = sample()
        planner.preferences.notchTaskCount = true
        planner.preferences.notchTimePill = true
        planner.tasks.append(PlanTask(title: "Private tomorrow", day: today.adding(days: 1), createdAt: now))
        let faces = pills(planner)
        XCTAssertEqual(faces.map(\.kind), [.time, .tasks])
        XCTAssertEqual(faces.last?.text, "1 left")
        XCTAssertFalse(faces.contains { $0.accessibilityLabel.contains("Private") })
        planner.tasks[0].done = true
        XCTAssertEqual(pills(planner).map(\.kind), [.time])
    }

    func testNextBlockIsOnlyFutureScheduledTaskInLastFifteenMinutes() {
        var planner = sample()
        planner.preferences.notchNextBlock = true
        planner.tasks[0].startAt = now.addingTimeInterval(901)
        XCTAssertTrue(pills(planner).isEmpty)
        planner.tasks[0].startAt = now.addingTimeInterval(900)
        XCTAssertEqual(pills(planner).first?.kind, .nextBlock)
        planner.tasks[0].startAt = now
        XCTAssertTrue(pills(planner).isEmpty)
        planner.tasks[0].startAt = nil
        planner.tasks[0].remindAt = now.addingTimeInterval(600)
        XCTAssertTrue(pills(planner).isEmpty, "Reminders are not block starts")
    }

    func testManualPrivacyRemovesNumbersFromVisibleAccessibleAndHelpOutput() {
        var planner = sample()
        planner.preferences.notchTimePill = true
        planner.preferences.notchTaskCount = true
        planner.preferences.notchNextBlock = true
        planner.preferences.hideCountsAndTimes = true
        for face in pills(planner) {
            XCTAssertEqual(face.text, "")
            XCTAssertFalse(face.accessibilityLabel.contains { $0.isNumber })
            XCTAssertFalse(face.help.contains { $0.isNumber })
            XCTAssertTrue(face.showsDot)
        }
        planner.focus?.state = .paused
        XCTAssertFalse(pills(planner).first!.showsDot)
    }

    func testFlatDisplayPrivacyRedactsCountdownAndRestoresItWhenOff() {
        var planner = sample()
        let closed = NotchClosedPresentation(planner: planner)
        let shown = NotchFlatTabPresentation(closed: closed, hideValues: false, now: now)
        XCTAssertEqual(shown.text, "24:10")
        XCTAssertTrue(shown.accessibilityLabel.contains("24:10"))
        let hidden = NotchFlatTabPresentation(closed: closed, hideValues: true, now: now)
        XCTAssertEqual(hidden.text, "")
        XCTAssertFalse(hidden.accessibilityLabel.contains { $0.isNumber })
        XCTAssertTrue(hidden.showsDot)
        planner.focus?.state = .paused
        let paused = NotchFlatTabPresentation(
            closed: NotchClosedPresentation(planner: planner), hideValues: true, now: now)
        XCTAssertFalse(paused.showsDot)
        XCTAssertFalse(paused.accessibilityLabel.contains { $0.isNumber })
        planner.focus = nil
        let idle = NotchFlatTabPresentation(
            closed: NotchClosedPresentation(planner: planner), hideValues: true, now: now)
        XCTAssertFalse(idle.visible)
    }

    func testGeometryIs24HighSixFromHousingClampedAndSymmetric() {
        let housing = CGRect(x: -950, y: 916, width: 190, height: 34)
        var planner = sample()
        planner.preferences.notchTimePill = true
        planner.preferences.notchTaskCount = true
        planner.preferences.notchNextBlock = true
        let faces = pills(planner)
        for placement in [NotchTimerPlacement.left, .right, .split] {
            let frames = NotchPillLayout.frames(pills: faces, housing: housing, placement: placement)
            XCTAssertEqual(frames.count, 3)
            for (index, frame) in frames.enumerated() {
                XCTAssertEqual(frame.height, 24)
                XCTAssertLessThanOrEqual(frame.width, 96)
                XCTAssertEqual(frame.midY, housing.midY)
                XCTAssertFalse(frame.intersects(housing))
                for other in frames.dropFirst(index + 1) { XCTAssertFalse(frame.intersects(other)) }
            }
            if placement == .left { XCTAssertEqual(frames[0].maxX, housing.minX - 6) }
            if placement == .right || placement == .split { XCTAssertEqual(frames[0].minX, housing.maxX + 6) }
            if placement == .split { XCTAssertEqual(frames[1].maxX, housing.minX - 6) }
        }
        XCTAssertEqual(NotchPillLayout.width(text: String(repeating: "9", count: 200), showsDot: true), 96)
        XCTAssertTrue(NotchPillLayout.frames(pills: faces, housing: housing, placement: .hidden).isEmpty)
    }

    private func sample() -> Planner {
        var planner = Planner()
        planner.preferences.hideCountsAndTimes = false
        planner.tasks = [
            PlanTask(title: "Private task", day: today, createdAt: now, startAt: now.addingTimeInterval(600))
        ]
        planner.focus = FocusSession(taskID: nil, limit: 1450, now: now)
        return planner
    }

    private func pills(_ planner: Planner, at date: Date? = nil) -> [NotchPillPresentation] {
        NotchPillPresentation.make(
            planner: planner, today: today, now: date ?? now, locale: Locale(identifier: "en_US_POSIX"))
    }
}
