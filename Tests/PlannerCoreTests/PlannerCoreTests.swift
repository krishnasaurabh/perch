import XCTest
@testable import PlannerCore

/// Fixed clock: Monday 2026-11-09 15:00 in Los Angeles.
enum Fixture {
    static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    static func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }
    static let now = date("2026-11-09 15:00")
    static var capture: TaskCapture { TaskCapture(now: now, calendar: calendar) }
    static func hm(_ d: Date?) -> String? {
        guard let d else { return nil }
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }
}

final class TaskCaptureTests: XCTestCase {
    let cap = Fixture.capture

    func testHeadlineExample() {
        let c = cap.parse("text dad tomorrow at 5pm !high #home")
        XCTAssertEqual(c.title, "Text dad")
        XCTAssertEqual(c.day, "2026-11-10")
        XCTAssertEqual(Fixture.hm(c.remindAt), "2026-11-10 17:00")
        XCTAssertEqual(c.priority, .high)
        XCTAssertEqual(c.projectName, "home")
    }

    func testTimeWithoutDayInPastRollsToTomorrow() {
        let c = cap.parse("standup at 9am")
        XCTAssertEqual(c.day, "2026-11-10")
        XCTAssertEqual(Fixture.hm(c.remindAt), "2026-11-10 09:00")
        XCTAssertEqual(c.title, "Standup")
    }

    func testTimeLaterToday() {
        let c = cap.parse("call mom at 5pm")
        XCTAssertEqual(c.day, "2026-11-09")
        XCTAssertEqual(Fixture.hm(c.remindAt), "2026-11-09 17:00")
    }

    func testBareAtHourReadsAsAfternoon() {
        XCTAssertEqual(Fixture.hm(cap.parse("pickup at 5").remindAt), "2026-11-09 17:00")
        XCTAssertEqual(Fixture.hm(cap.parse("ship at 5:30").remindAt), "2026-11-09 17:30")
        XCTAssertNil(cap.parse("read at 5 pages").remindAt)
    }

    func testNoonAndRelative() {
        XCTAssertEqual(Fixture.hm(cap.parse("lunch tomorrow at noon").remindAt), "2026-11-10 12:00")
        XCTAssertEqual(Fixture.hm(cap.parse("check oven in 20 minutes").remindAt), "2026-11-09 15:20")
        XCTAssertEqual(Fixture.hm(cap.parse("stretch in half an hour").remindAt), "2026-11-09 15:30")
        XCTAssertEqual(Fixture.hm(cap.parse("call back in two hours").remindAt), "2026-11-09 17:00")
    }

    func testWeekdays() {
        XCTAssertEqual(cap.parse("vet friday at 10").day, "2026-11-13")
        XCTAssertEqual(cap.parse("vet friday at 10").title, "Vet")
        XCTAssertEqual(cap.parse("review next monday").day, "2026-11-16")
        XCTAssertEqual(cap.parse("review monday").day, "2026-11-09")
        XCTAssertEqual(cap.parse("lunch on thu").day, "2026-11-12")
    }

    func testDates() {
        XCTAssertEqual(cap.parse("anniversary dinner dec 15").day, "2026-12-15")
        XCTAssertEqual(cap.parse("renew passport on the 3rd").day, "2026-12-03")
        XCTAssertEqual(cap.parse("tax prep 15th of april").day, "2027-04-15")
        XCTAssertEqual(cap.parse("call bank in 3 days").day, "2026-11-12")
        XCTAssertEqual(cap.parse("plan trip in 2 weeks").day, "2026-11-23")
        XCTAssertEqual(cap.parse("thing the day after tomorrow").day, "2026-11-11")
        XCTAssertEqual(cap.parse("x 2026-12-01").day, "2026-12-01")
    }

    func testDeadlineIsNotThePlannedDay() {
        let c = cap.parse("finish report due friday")
        XCTAssertEqual(c.deadline, "2026-11-13")
        XCTAssertNil(c.day)
        XCTAssertEqual(c.title, "Finish report")
    }

    func testDurationAndPriorityVariants() {
        XCTAssertEqual(cap.parse("deep work for 90 min").minutes, 90)
        XCTAssertEqual(cap.parse("deep work for 1.5h").minutes, 90)
        XCTAssertEqual(cap.parse("write tests (45m)").minutes, 45)
        XCTAssertEqual(cap.parse("pay rent !!!").priority, .high)
        XCTAssertEqual(cap.parse("pay rent p2").priority, .medium)
        XCTAssertEqual(cap.parse("pay rent !").priority, .low)
        XCTAssertEqual(cap.parse("Hello! world").priority, .none)
    }

    func testRepeats() {
        let c = cap.parse("gym every monday, wednesday and friday at 7am")
        XCTAssertEqual(c.repeatRule, TaskRepeat(unit: .week, weekdays: [2, 4, 6]))
        XCTAssertEqual(c.title, "Gym")
        XCTAssertEqual(cap.parse("water plants every 3 days").repeatRule, TaskRepeat(unit: .day, interval: 3))
        XCTAssertEqual(cap.parse("haircut every! 4 weeks").repeatRule, TaskRepeat(unit: .week, interval: 4, fromCompletion: true))
        XCTAssertEqual(cap.parse("standup weekdays").repeatRule, .weekdaysRule)
        XCTAssertEqual(cap.parse("1:1 every other week on tue").repeatRule, TaskRepeat(unit: .week, interval: 2, weekdays: [3]))
        XCTAssertEqual(cap.parse("review daily").repeatRule, .daily)
    }

    func testInbox() {
        let c = cap.parse("learn piano someday")
        XCTAssertTrue(c.inbox)
        XCTAssertNil(c.day)
        XCTAssertEqual(c.title, "Learn piano")
        XCTAssertTrue(cap.parse("read SICP #inbox").inbox)
    }

    func testBulletsAndConnectors() {
        XCTAssertEqual(TaskCapture.splitLines("- buy milk\n2) call mom\n\n* then and pay rent"), ["buy milk", "call mom", "pay rent"])
    }

    func testTitleOnlyFallsBack() {
        XCTAssertEqual(cap.parse("tomorrow").title, "tomorrow")
    }
}

final class TaskRepeatTests: XCTestCase {
    let cal = Fixture.calendar

    func testNextWeekdayInList() {
        let r = TaskRepeat(unit: .week, weekdays: [2, 4, 6])  // mon wed fri
        XCTAssertEqual(r.next(after: "2026-11-09", completed: "2026-11-09", calendar: cal), "2026-11-11")
        XCTAssertEqual(r.next(after: "2026-11-13", completed: "2026-11-13", calendar: cal), "2026-11-16")
    }

    func testEveryOtherWeek() {
        let r = TaskRepeat(unit: .week, interval: 2, weekdays: [3])  // tue
        XCTAssertEqual(r.next(after: "2026-11-10", completed: "2026-11-10", calendar: cal), "2026-11-24")
    }

    func testFromCompletion() {
        let r = TaskRepeat(unit: .day, interval: 3, fromCompletion: true)
        XCTAssertEqual(r.next(after: "2026-11-01", completed: "2026-11-09", calendar: cal), "2026-11-12")
    }

    func testWeekdaysSkipsWeekend() {
        XCTAssertEqual(TaskRepeat.weekdaysRule.next(after: "2026-11-13", completed: "2026-11-13", calendar: cal), "2026-11-16")
    }

    func testMonthlyAndRoundTrip() {
        XCTAssertEqual(TaskRepeat.monthly.next(after: "2026-01-31", completed: "2026-01-31", calendar: cal), "2026-02-28")
        for s in ["every day", "every 2 weeks", "every mon, wed", "every! 3 days", "every weekday", "every month"] {
            let r = TaskRepeat.parseRule(s)!!
            XCTAssertEqual(TaskRepeat.parseRule(r.description)!!, r, s)
        }
        XCTAssertNil(TaskRepeat.parseRule("sometimes"))
        XCTAssertEqual(TaskRepeat.parseRule("none")!, nil)
    }
}

final class PlannerEngineTests: XCTestCase {
    var clock = Fixture.now
    lazy var engine = PlannerEngine(planner: Planner(), now: { [unowned self] in self.clock }, calendar: Fixture.calendar)

    func testAddDefaultsToTodayAndCreatesProject() throws {
        let t = try engine.addTasks(["write tests #perch"]).first!
        XCTAssertEqual(t.day, "2026-11-09")
        XCTAssertEqual(engine.planner.projects.map(\.name), ["Perch"])
        _ = try engine.addTasks(["more #PERCH"])
        XCTAssertEqual(engine.planner.projects.count, 1)
    }

    func testCannotAddToPast() {
        XCTAssertThrowsError(try engine.addTasks(["x"], on: .day("2026-11-01")))
    }

    func testLiteral() throws {
        let t = try engine.addTasks(["buy 5pm tickets !high"], literal: true).first!
        XCTAssertEqual(t.title, "buy 5pm tickets !high")
        XCTAssertNil(t.remindAt)
    }

    func testRepeatWithoutDayStartsOnFirstMatchingWeekday() throws {
        // Fixture is Monday; "every wed, fri" should land on Wednesday, not today.
        let t = try engine.addTasks(["swim every wed, fri"]).first!
        XCTAssertEqual(t.day, "2026-11-11")
        let u = try engine.addTasks(["gym every mon, wed"]).first!
        XCTAssertEqual(u.day, "2026-11-09")
    }

    func testCompleteRepeatingPlansNextCopy() throws {
        _ = try engine.addTasks(["standup at 9:30pm every weekday"])
        _ = try engine.complete("Standup")
        let next = engine.planner.tasks.first { !$0.done }!
        XCTAssertEqual(next.day, "2026-11-10")
        XCTAssertEqual(Fixture.hm(next.remindAt), "2026-11-10 21:30")
        XCTAssertThrowsError(try engine.complete("Standup"))  // today's copy is already done
    }

    func testOnlyTodayCanBeCompleted() throws {
        _ = try engine.addTasks(["later thing tomorrow"])
        XCTAssertThrowsError(try engine.complete("Later thing"))
    }

    func testAmbiguousTitle() throws {
        _ = try engine.addTasks(["email alice", "email bob"])
        XCTAssertThrowsError(try engine.complete("email")) { e in
            XCTAssertTrue("\(e)".contains("Multiple tasks match"))
        }
        XCTAssertNoThrow(try engine.complete("email bob"))
    }

    func testShortIdLookup() throws {
        let t = try engine.addTasks(["a"]).first!
        let short = String(t.id.uuidString.prefix(8)).lowercased()
        XCTAssertEqual(try engine.complete(short).id, t.id)
    }

    func testMoveToInboxDropsReminderAndRepeat() throws {
        _ = try engine.addTasks(["gym at 6pm every day"])
        let t = try engine.move("Gym", from: .day("2026-11-09"), to: .inbox)
        XCTAssertNil(t.day); XCTAssertNil(t.remindAt); XCTAssertNil(t.repeatRule)
        let back = try engine.move("Gym", from: .inbox, to: .day("2026-11-12"))
        XCTAssertEqual(back.day, "2026-11-12")
    }

    func testPastDaysReadOnly() throws {
        engine.planner.tasks.append(PlanTask(title: "old", day: "2026-11-01"))
        XCTAssertThrowsError(try engine.rename("old", on: .day("2026-11-01"), to: "new"))
        XCTAssertThrowsError(try engine.writeNotepad(on: "2026-11-01", text: "x"))
    }

    func testUpdateFields() throws {
        _ = try engine.addTasks(["report"])
        var e = TaskEdit()
        e.remindAt = "5:30 pm"; e.priority = "high"; e.project = "Work"; e.repeatRule = "every mon, wed"
        e.minutes = 50; e.steps = ["outline", "draft", "edit"]; e.doneSteps = ["outline"]; e.deadline = "2026-11-20"
        let t = try engine.update("report", on: .day("2026-11-09"), e)
        XCTAssertEqual(Fixture.hm(t.remindAt), "2026-11-09 17:30")
        XCTAssertEqual(t.priority, .high)
        XCTAssertEqual(t.repeatRule, TaskRepeat(unit: .week, weekdays: [2, 4]))
        XCTAssertEqual(t.minutes, 50)
        XCTAssertEqual(t.steps.filter(\.done).map(\.title), ["outline"])
        XCTAssertEqual(t.deadline, "2026-11-20")

        var keep = TaskEdit(); keep.steps = ["outline", "draft", "edit", "publish"]
        let t2 = try engine.update("report", on: .day("2026-11-09"), keep)
        XCTAssertEqual(t2.steps.filter(\.done).map(\.title), ["outline"], "existing step progress is kept")

        var past = TaskEdit(); past.remindAt = "9:00 am"
        XCTAssertThrowsError(try engine.update("report", on: .day("2026-11-09"), past))
        XCTAssertThrowsError(try engine.update("report", on: .day("2026-11-09"), TaskEdit()))
        var bad = TaskEdit(); bad.repeatRule = "sometimes"
        XCTAssertThrowsError(try engine.update("report", on: .day("2026-11-09"), bad))
    }

    func testReminderFormats() throws {
        let d: DayKey = "2026-11-09"
        XCTAssertEqual(Fixture.hm(try engine.parseReminder("17:30", on: d)), "2026-11-09 17:30")
        XCTAssertEqual(Fixture.hm(try engine.parseReminder("2026-10-30 17:30", on: d)), "2026-10-30 17:30")
        XCTAssertEqual(Fixture.hm(try engine.parseReminder("in 20 minutes", on: d)), "2026-11-09 15:20")
        XCTAssertEqual(Fixture.hm(try engine.parseReminder("tomorrow at 9", on: d)), "2026-11-10 09:00")
        XCTAssertThrowsError(try engine.parseReminder("whenever", on: d))
    }

    func testTimerCountdownPauseResumeAndInsights() throws {
        _ = try engine.addTasks(["deep work"])
        try engine.startTimer(task: "deep work", minutes: 25)
        clock += 10 * 60
        try engine.pauseTimer()
        clock += 60 * 60  // paused time doesn't count
        try engine.resumeTimer()
        clock += 20 * 60
        XCTAssertTrue(engine.tick(), "countdown finished at 25 min")
        XCTAssertEqual(engine.planner.tasks[0].focusedSeconds, 25 * 60, accuracy: 0.5)
        XCTAssertEqual(engine.planner.tasks[0].minutes, 25)
        XCTAssertEqual(engine.insights().today.focusSeconds, 25 * 60, accuracy: 0.5)
        XCTAssertThrowsError(try engine.pauseTimer())
    }

    func testCompletingStopsTimer() throws {
        _ = try engine.addTasks(["a"])
        try engine.startTimer(task: "a", minutes: nil)
        clock += 300
        _ = try engine.complete("a")
        XCTAssertNil(engine.planner.focus)
        XCTAssertEqual(engine.planner.tasks[0].focusedSeconds, 300, accuracy: 0.5)
    }

    func testStreak() throws {
        for (offset, done) in [(-3, true), (-2, true), (-1, true), (0, false)] {
            var t = PlanTask(title: "t\(offset)", day: DayKey(Fixture.now, calendar: Fixture.calendar).adding(days: offset, calendar: Fixture.calendar))
            t.done = done
            engine.planner.tasks.append(t)
        }
        XCTAssertEqual(engine.insights().streak, 3, "today still empty, so streak counts from yesterday")
    }

    func testOverdueCarryAndDismiss() throws {
        engine.planner.tasks.append(PlanTask(title: "unfinished", day: "2026-11-05"))
        engine.planner.tasks.append(PlanTask(title: "also", day: "2026-11-06"))
        XCTAssertEqual(engine.overdue().count, 2)
        let first = engine.overdue()[0].id
        engine.carryForward([first], to: "2026-11-09")
        XCTAssertEqual(engine.overdue().map(\.title), ["also"])
        engine.dismissOverdue(engine.overdue().map(\.id))
        XCTAssertTrue(engine.overdue().isEmpty)
        XCTAssertEqual(engine.tasks(on: .day("2026-11-09")).first?.carriedFrom, "2026-11-05")
    }

    func testNotepadAndLineToTask() throws {
        try engine.writeNotepad(on: "2026-11-09", text: "first")
        try engine.writeNotepad(on: "2026-11-09", text: "second")
        XCTAssertEqual(engine.notepad(on: "2026-11-09"), "first\nsecond")
        try engine.writeNotepad(on: "2026-11-09", text: "only", mode: "replace")
        XCTAssertEqual(engine.notepad(on: "2026-11-09"), "only")
        let t = try engine.lineToTask("email Sam tomorrow", day: "2026-11-09")
        XCTAssertEqual(t?.day, "2026-11-10")
    }
}

final class PlannerFileTests: XCTestCase {
    func testRoundTripAndCorruptPreserved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = PlannerFile(url: dir.appendingPathComponent("planner.json"))
        try file.mutate { p in
            var e = PlannerEngine(planner: p, now: { Fixture.now }, calendar: Fixture.calendar)
            _ = try e.addTasks(["a #x every day at 6pm"])
            p = e.planner
        }
        let p = try file.load()
        XCTAssertEqual(p.tasks.first?.repeatRule, .daily)
        XCTAssertEqual(p.projects.first?.name, "X")

        try Data("{not json".utf8).write(to: file.url)
        XCTAssertThrowsError(try file.load())
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(siblings.contains { $0.contains("corrupt") })
    }

    func testOldFileWithMissingKeysStillLoads() throws {
        let json = #"{"tasks":[],"preferences":{"defaultFocusMinutes":50}}"#
        let p = try PlannerFile.decoder.decode(Planner.self, from: Data(json.utf8))
        XCTAssertEqual(p.preferences.defaultFocusMinutes, 50)
        XCTAssertEqual(p.preferences.workspaceTimerStyle, .digital)
    }
}
