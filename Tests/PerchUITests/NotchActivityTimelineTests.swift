import PlannerTestSupport
import XCTest
@testable import PlannerCore
@testable import PerchUI

final class NotchActivityTimelineTests: XCTestCase {
    let time = Fixture.now

    func activity(_ kind: NotchActivity.Kind, _ id: String, at date: Date? = nil) -> NotchActivity {
        NotchActivity(kind: kind, title: id, date: date ?? time, id: id)
    }

    func testConstantsAreExplicitPresentationPolicy() {
        XCTAssertEqual(NotchActivityTimeline.eventLead, 300)
        XCTAssertEqual(NotchActivityTimeline.lateGrace, 60)
        XCTAssertEqual(NotchActivityTimeline.reminderDuration, 60)
        XCTAssertEqual(NotchActivityTimeline.screenshotDuration, 8)
    }

    func testTriggersIncludeOpenRemindersBothEventPhasesAndScreenshots() {
        var p = Planner()
        let task = PlanTask(title: "Call", day: "2026-11-09", remindAt: time)
        p.tasks = [
            task,
            PlanTask(title: "Done", day: "2026-11-09", done: true, remindAt: time),
            PlanTask(title: "Inbox", day: nil, remindAt: time),
            PlanTask(title: "No alarm", day: "2026-11-09"),
        ]
        let event = NotchActivityTimeline.Event(id: "event", title: "Meeting", start: time.addingTimeInterval(600))
        let allDay = NotchActivityTimeline.Event(id: "all-day", title: "Holiday", start: time, isAllDay: true)
        let url = URL(fileURLWithPath: "/screenshots/capture.png")
        let screenshot = NotchActivityTimeline.Screenshot(id: "capture", title: "Screenshot", date: time, fileURL: url)
        let triggers = NotchActivityTimeline.triggers(planner: p, events: [event, allDay], screenshots: [screenshot])
        XCTAssertEqual(triggers.count, 4)
        XCTAssertEqual(Set(triggers.map(\.kind)), [.reminder, .eventSoon, .eventNow, .screenshot])
        XCTAssertEqual(triggers.first { $0.kind == .reminder }?.taskID, task.id)
        XCTAssertEqual(triggers.first { $0.kind == .eventSoon }?.date, time.addingTimeInterval(300))
        XCTAssertEqual(triggers.first { $0.kind == .eventNow }?.date, event.start)
        XCTAssertEqual(triggers.first { $0.kind == .screenshot }?.fileURL, url)
        XCTAssertEqual(
            triggers, NotchActivityTimeline.triggers(planner: p, events: [event, allDay], screenshots: [screenshot]))
    }

    func testEveryKindHasHalfOpenVisibilityWindow() {
        for kind in NotchActivity.Kind.allCases {
            let a = activity(kind, kind.rawValue)
            let timeline = NotchActivityTimeline(activities: [a])
            XCTAssertNil(timeline.showing(at: time.addingTimeInterval(-0.001)))
            XCTAssertEqual(timeline.showing(at: time), a)
            XCTAssertEqual(timeline.showing(at: a.end.addingTimeInterval(-0.001)), a)
            XCTAssertNil(timeline.showing(at: a.end))
            XCTAssertNil(timeline.showing(at: a.end.addingTimeInterval(600)))
            XCTAssertNil(timeline.showing(at: time, dismissed: [a.id]))
            XCTAssertEqual(timeline.nextChange(after: time.addingTimeInterval(-1)), time)
            XCTAssertEqual(timeline.nextChange(after: time), a.end)
            XCTAssertNil(timeline.nextChange(after: a.end))
        }
    }

    func testEventSoonTransitionsToNowThenExpires() {
        let event = NotchActivityTimeline.Event(id: "meeting", title: "Meeting", start: time)
        let timeline = NotchActivityTimeline(planner: Planner(), events: [event])
        XCTAssertNil(timeline.showing(at: time.addingTimeInterval(-301)))
        let soon = timeline.showing(at: time.addingTimeInterval(-300))!
        XCTAssertEqual(soon.kind, .eventSoon)
        XCTAssertEqual(timeline.nextChange(after: soon.date), time)
        XCTAssertEqual(timeline.showing(at: time)?.kind, .eventNow)
        XCTAssertNotEqual(soon.id, timeline.showing(at: time)?.id)
        XCTAssertEqual(timeline.nextChange(after: time), time.addingTimeInterval(60))
        XCTAssertNil(timeline.showing(at: time.addingTimeInterval(60)))
        XCTAssertEqual(timeline.showing(at: time, dismissed: [soon.id])?.kind, .eventNow)
    }

    func testPriorityDismissalAndPreemptionAreDeterministic() {
        let reminder = activity(.reminder, "reminder")
        let event = activity(.eventNow, "event")
        let shot = activity(.screenshot, "shot")
        let soon = activity(.eventSoon, "soon")
        let timeline = NotchActivityTimeline(activities: [soon, shot, reminder, event])
        XCTAssertEqual(timeline.showing(at: time), event)
        XCTAssertEqual(timeline.showing(at: time, dismissed: [event.id]), reminder)
        XCTAssertEqual(timeline.showing(at: time, dismissed: [event.id, reminder.id]), shot)
        XCTAssertEqual(timeline.showing(at: time, dismissed: [event.id, reminder.id, shot.id]), soon)
        XCTAssertNil(timeline.showing(at: time, dismissed: Set([event.id, reminder.id, shot.id, soon.id])))
        XCTAssertEqual(
            timeline.nextChange(after: time), event.end, "skip changes hidden behind higher-priority activity")
        XCTAssertEqual(timeline.nextChange(after: time, dismissed: [event.id, reminder.id]), shot.end)
    }

    func testTieBreaksUseNewestThenLexicalIDIndependentOfInputOrder() {
        let older = activity(.reminder, "older", at: time.addingTimeInterval(-5))
        let a = activity(.reminder, "a")
        let b = activity(.reminder, "b")
        for activities in [[older, b, a], [a, older, b]] {
            let timeline = NotchActivityTimeline(activities: activities)
            XCTAssertEqual(timeline.showing(at: time), a)
            XCTAssertEqual(timeline.showing(at: time, dismissed: [a.id]), b)
        }
    }

    func testNextChangeFindsNewHigherPriorityActivityThenReturnsToOldOne() {
        let soon = activity(.eventSoon, "soon")
        let shot = activity(.screenshot, "shot", at: time.addingTimeInterval(10))
        let timeline = NotchActivityTimeline(activities: [soon, shot])
        XCTAssertEqual(timeline.nextChange(after: time), shot.date)
        XCTAssertEqual(timeline.nextChange(after: shot.date), shot.end)
        XCTAssertEqual(timeline.showing(at: shot.end), soon)
        XCTAssertEqual(timeline.nextChange(after: shot.end), soon.end)
        XCTAssertNil(timeline.nextChange(after: soon.end))
    }

    func testSnoozedReminderHasNewStableIdentityAndCompletedTaskDisappears() {
        var p = Planner()
        p.tasks = [PlanTask(title: "Call", day: "2026-11-09", remindAt: time)]
        let old = NotchActivityTimeline(planner: p).showing(at: time)!
        p.tasks[0].remindAt = time.addingTimeInterval(300)
        let snoozed = NotchActivityTimeline(planner: p)
        let new = snoozed.showing(at: time.addingTimeInterval(300), dismissed: [old.id])!
        XCTAssertNotEqual(new.id, old.id)
        XCTAssertEqual(new.taskID, old.taskID)
        p.tasks[0].done = true
        XCTAssertTrue(NotchActivityTimeline(planner: p).activities.isEmpty)
    }

    func testEmptyTimelineHasNoVisibilityOrWakeup() {
        let timeline = NotchActivityTimeline(planner: Planner())
        XCTAssertNil(timeline.showing(at: time))
        XCTAssertNil(timeline.nextChange(after: time))
    }
}
