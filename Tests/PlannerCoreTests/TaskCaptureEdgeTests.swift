import XCTest
@testable import PlannerCore

/// Adversarial natural-language capture coverage, separate from PlannerCoreTests.
/// Fixture clock: Monday 2026-11-09 15:00 America/Los_Angeles (PST, UTC-8).
private struct CaptureCase {
    let input: String
    let title: String
    var day: String? = nil
    var remind: String? = nil
    var deadline: String? = nil
    var priority: TaskPriority = .none
    var project: String? = nil
    var repeatRule: TaskRepeat? = nil
    var minutes: Int? = nil
    var inbox: Bool = false
}

final class TaskCaptureEdgeTests: XCTestCase {
    private let cap = Fixture.capture

    // MARK: Corpora

    private static let timeCases: [CaptureCase] = [
        CaptureCase(input: "call mom at 5pm", title: "Call mom", day: "2026-11-09", remind: "2026-11-09 17:00"),
        CaptureCase(input: "call mom at 5 pm", title: "Call mom", day: "2026-11-09", remind: "2026-11-09 17:00"),
        CaptureCase(input: "call mom at 5pm.", title: "Call mom", day: "2026-11-09", remind: "2026-11-09 17:00"),
        CaptureCase(input: "call mom 5pm", title: "Call mom", day: "2026-11-09", remind: "2026-11-09 17:00"),
        CaptureCase(input: "call mom @5pm", title: "Call mom", day: "2026-11-09", remind: "2026-11-09 17:00"),
        CaptureCase(input: "call mom at 17:30", title: "Call mom", day: "2026-11-09", remind: "2026-11-09 17:30"),
        CaptureCase(input: "call mom at 5:30", title: "Call mom", day: "2026-11-09", remind: "2026-11-09 17:30"),
        CaptureCase(input: "call mom at 12am", title: "Call mom", day: "2026-11-10", remind: "2026-11-10 00:00"),
        CaptureCase(input: "call mom at 12 pm", title: "Call mom", day: "2026-11-10", remind: "2026-11-10 12:00"),
        CaptureCase(input: "call mom at 12:30am", title: "Call mom", day: "2026-11-10", remind: "2026-11-10 00:30"),
        CaptureCase(input: "call mom at noon", title: "Call mom", day: "2026-11-10", remind: "2026-11-10 12:00"),
        CaptureCase(input: "call mom at midnight", title: "Call mom", day: "2026-11-10", remind: "2026-11-10 00:00"),
        CaptureCase(input: "call mom at midday", title: "Call mom", day: "2026-11-10", remind: "2026-11-10 12:00"),
        CaptureCase(input: "call mom around 6pm", title: "Call mom", day: "2026-11-09", remind: "2026-11-09 18:00"),
        CaptureCase(input: "call mom by 6pm", title: "Call mom", day: "2026-11-09", remind: "2026-11-09 18:00"),
        CaptureCase(input: "call mom at 9", title: "Call mom", day: "2026-11-10", remind: "2026-11-10 09:00"),
        CaptureCase(input: "call mom at 21", title: "Call mom", day: "2026-11-09", remind: "2026-11-09 21:00"),
        CaptureCase(input: "call mom at 0", title: "Call mom", day: "2026-11-10", remind: "2026-11-10 00:00"),
        CaptureCase(input: "call mom at 23:59", title: "Call mom", day: "2026-11-09", remind: "2026-11-09 23:59"),
        CaptureCase(input: "call mom at 5pm tomorrow", title: "Call mom", day: "2026-11-10", remind: "2026-11-10 17:00"),
        CaptureCase(input: "read at 5 pages", title: "Read at 5 pages"),
        CaptureCase(input: "meeting at 1", title: "Meeting", day: "2026-11-10", remind: "2026-11-10 13:00"),
        CaptureCase(input: "at 8", title: "at 8", day: "2026-11-10", remind: "2026-11-10 08:00"),
        CaptureCase(input: "call at 8pm tomorrow", title: "Call", day: "2026-11-10", remind: "2026-11-10 20:00"),
        CaptureCase(input: "lunch tomorrow noon", title: "Lunch", day: "2026-11-10", remind: "2026-11-10 12:00"),
        CaptureCase(input: "x 5:30am", title: "X", day: "2026-11-10", remind: "2026-11-10 05:30"),
        CaptureCase(input: "x at 12:00", title: "X", day: "2026-11-10", remind: "2026-11-10 12:00"),
        CaptureCase(input: "x 12:00pm", title: "X", day: "2026-11-10", remind: "2026-11-10 12:00"),
        CaptureCase(input: "x at 00:00", title: "X", day: "2026-11-10", remind: "2026-11-10 00:00"),
        CaptureCase(input: "x at 24:00", title: "X at 24:00"),
        CaptureCase(input: "x at 19:30", title: "X", day: "2026-11-09", remind: "2026-11-09 19:30"),
        CaptureCase(input: "call mom at 5 P.M.", title: "Call mom", day: "2026-11-09", remind: "2026-11-09 17:00"),
        CaptureCase(input: "call mom at 5 p.m", title: "Call mom", day: "2026-11-09", remind: "2026-11-09 17:00"),
        CaptureCase(input: "Call Mom at 5PM", title: "Call Mom", day: "2026-11-09", remind: "2026-11-09 17:00"),
        CaptureCase(input: "x at 7:00am", title: "X", day: "2026-11-10", remind: "2026-11-10 07:00"),
        CaptureCase(input: "dentist at 10am on friday", title: "Dentist", day: "2026-11-13", remind: "2026-11-13 10:00"),
        CaptureCase(input: "vet friday at 10", title: "Vet", day: "2026-11-13", remind: "2026-11-13 10:00"),
        CaptureCase(input: "Friday standup at 9", title: "Standup", day: "2026-11-13", remind: "2026-11-13 09:00"),
        CaptureCase(input: "SUNDAY brunch at 11am", title: "Brunch", day: "2026-11-15", remind: "2026-11-15 11:00"),
    ]

    private static let dateCases: [CaptureCase] = [
        CaptureCase(input: "new year jan 1", title: "New year", day: "2027-01-01"),
        CaptureCase(input: "party dec 31", title: "Party", day: "2026-12-31"),
        CaptureCase(input: "party dec 31 2026", title: "Party", day: "2026-12-31"),
        CaptureCase(input: "party jan 1 2027", title: "Party", day: "2027-01-01"),
        CaptureCase(input: "review sep 1", title: "Review", day: "2027-09-01"),
        CaptureCase(input: "review september 1st", title: "Review", day: "2027-09-01"),
        CaptureCase(input: "review 1st of september", title: "Review", day: "2027-09-01"),
        CaptureCase(input: "review on the 15th", title: "Review", day: "2026-11-15"),
        CaptureCase(input: "review on the 31st", title: "Review", day: "2026-12-31"),
        CaptureCase(input: "plan feb 28", title: "Plan", day: "2027-02-28"),
        CaptureCase(input: "plan feb 29 2028", title: "Plan", day: "2028-02-29"),
        CaptureCase(input: "plan mar 1", title: "Plan", day: "2027-03-01"),
        CaptureCase(input: "x dec 31 at 11:59pm", title: "X", day: "2026-12-31", remind: "2026-12-31 23:59"),
        CaptureCase(input: "party dec 31 at 8pm", title: "Party", day: "2026-12-31", remind: "2026-12-31 20:00"),
        CaptureCase(input: "x nov 30 at 11:59pm", title: "X", day: "2026-11-30", remind: "2026-11-30 23:59"),
        CaptureCase(input: "x 2026-12-31", title: "X", day: "2026-12-31"),
        CaptureCase(input: "x 2027-01-01 at 00:30", title: "X", day: "2027-01-01", remind: "2027-01-01 00:30"),
        CaptureCase(input: "x 2028-02-29", title: "X", day: "2028-02-29"),
        CaptureCase(input: "x 2026-13-01", title: "X 2026-13-01"),
        CaptureCase(input: "x feb 28 2028", title: "X", day: "2028-02-28"),
        CaptureCase(input: "x sep 30", title: "X", day: "2027-09-30"),
        CaptureCase(input: "tax prep apr 15", title: "Tax prep", day: "2027-04-15"),
        CaptureCase(input: "renew passport on the 3rd", title: "Renew passport", day: "2026-12-03"),
        CaptureCase(input: "x december 31st", title: "X", day: "2026-12-31"),
        CaptureCase(input: "x Dec. 31", title: "X", day: "2026-12-31"),
        CaptureCase(input: "x on the 1st", title: "X", day: "2026-12-01"),
        CaptureCase(input: "call bank in 3 days", title: "Call bank", day: "2026-11-12"),
        CaptureCase(input: "plan trip in 2 weeks", title: "Plan trip", day: "2026-11-23"),
        CaptureCase(input: "in 10 days", title: "in 10 days", day: "2026-11-19"),
        CaptureCase(input: "in a week", title: "in a week", day: "2026-11-16"),
        CaptureCase(input: "in 0 days", title: "in 0 days", day: "2026-11-09"),
    ]

    private static let dayWordCases: [CaptureCase] = [
        CaptureCase(input: "today", title: "today", day: "2026-11-09"),
        CaptureCase(input: "tonight", title: "tonight", day: "2026-11-09"),
        CaptureCase(input: "this evening", title: "this evening", day: "2026-11-09"),
        CaptureCase(input: "tomorrow", title: "tomorrow", day: "2026-11-10"),
        CaptureCase(input: "tmrw", title: "tmrw", day: "2026-11-10"),
        CaptureCase(input: "tmr", title: "tmr", day: "2026-11-10"),
        CaptureCase(input: "day after tomorrow", title: "day after tomorrow", day: "2026-11-11"),
        CaptureCase(input: "the day after tomorrow", title: "the day after tomorrow", day: "2026-11-11"),
        CaptureCase(input: "x tomorrow at 12am", title: "X", day: "2026-11-10", remind: "2026-11-10 00:00"),
    ]

    private static let weekdayCases: [CaptureCase] = [
        CaptureCase(input: "x monday", title: "X", day: "2026-11-09"),
        CaptureCase(input: "x this monday", title: "X", day: "2026-11-09"),
        CaptureCase(input: "x next monday", title: "X", day: "2026-11-16"),
        CaptureCase(input: "on thu", title: "on thu", day: "2026-11-12"),
        CaptureCase(input: "x friday", title: "X", day: "2026-11-13"),
        CaptureCase(input: "x this friday", title: "X", day: "2026-11-13"),
        CaptureCase(input: "x next friday", title: "X", day: "2026-11-20"),
        CaptureCase(input: "x next friday at 10am", title: "X", day: "2026-11-20", remind: "2026-11-20 10:00"),
        CaptureCase(input: "x saturday", title: "X", day: "2026-11-14"),
        CaptureCase(input: "x sunday", title: "X", day: "2026-11-15"),
        CaptureCase(input: "x next sunday", title: "X", day: "2026-11-22"),
    ]

    private static let repeatCases: [CaptureCase] = [
        CaptureCase(input: "gym every monday", title: "Gym", repeatRule: TaskRepeat(unit: .week, weekdays: [2])),
        CaptureCase(input: "gym every mon, wed and fri", title: "Gym", repeatRule: TaskRepeat(unit: .week, weekdays: [2, 4, 6])),
        CaptureCase(input: "gym every mon & wed", title: "Gym", repeatRule: TaskRepeat(unit: .week, weekdays: [2, 4])),
        CaptureCase(input: "gym every tuesday, thursday", title: "Gym", repeatRule: TaskRepeat(unit: .week, weekdays: [3, 5])),
        CaptureCase(input: "gym every tues", title: "Gym", repeatRule: TaskRepeat(unit: .week, weekdays: [3])),
        CaptureCase(input: "gym every thurs", title: "Gym", repeatRule: TaskRepeat(unit: .week, weekdays: [5])),
        CaptureCase(input: "gym every sun, sat", title: "Gym", repeatRule: TaskRepeat(unit: .week, weekdays: [1, 7])),
        CaptureCase(input: "gym every other tuesday", title: "Gym", repeatRule: TaskRepeat(unit: .week, interval: 2, weekdays: [3])),
        CaptureCase(input: "1:1 every other week on tue", title: "1:1", repeatRule: TaskRepeat(unit: .week, interval: 2, weekdays: [3])),
        CaptureCase(input: "gym every other day", title: "Gym", repeatRule: TaskRepeat(unit: .day, interval: 2)),
        CaptureCase(input: "gym every other week", title: "Gym", repeatRule: TaskRepeat(unit: .week, interval: 2)),
        CaptureCase(input: "gym every 2 weeks", title: "Gym", repeatRule: TaskRepeat(unit: .week, interval: 2)),
        CaptureCase(input: "gym every week", title: "Gym", repeatRule: .weekly),
        CaptureCase(input: "gym daily", title: "Gym", repeatRule: .daily),
        CaptureCase(input: "gym weekly", title: "Gym", repeatRule: .weekly),
        CaptureCase(input: "gym monthly", title: "Gym", repeatRule: .monthly),
        CaptureCase(input: "gym every month", title: "Gym", repeatRule: .monthly),
        CaptureCase(input: "gym every 3 months", title: "Gym", repeatRule: TaskRepeat(unit: .month, interval: 3)),
        CaptureCase(input: "gym every! 3 days", title: "Gym", repeatRule: TaskRepeat(unit: .day, interval: 3, fromCompletion: true)),
        CaptureCase(input: "gym weekdays", title: "Gym", repeatRule: .weekdaysRule),
        CaptureCase(input: "gym every weekday", title: "Gym", repeatRule: .weekdaysRule),
    ]

    private static let unicodeCases: [CaptureCase] = [
        CaptureCase(input: "🏋️ gym tomorrow at 7am", title: "🏋️ gym", day: "2026-11-10", remind: "2026-11-10 07:00"),
        CaptureCase(input: "café ☕ with Ana at 10am", title: "Café ☕ with Ana", day: "2026-11-10", remind: "2026-11-10 10:00"),
        CaptureCase(input: "日本語のタスク tomorrow", title: "日本語のタスク", day: "2026-11-10"),
        CaptureCase(input: "call 妈妈明天", title: "Call 妈妈明天"),
        CaptureCase(input: "pay ₹500 !high", title: "Pay ₹500", priority: .high),
        CaptureCase(input: "naïve résumé review", title: "Naïve résumé review"),
        CaptureCase(input: "👨‍👩‍👧‍👦 family dinner at 6pm", title: "👨‍👩‍👧‍👦 family dinner", day: "2026-11-09", remind: "2026-11-09 18:00"),
        CaptureCase(input: "🎉", title: "🎉"),
    ]

    private static let metadataOnlyCases: [CaptureCase] = [
        CaptureCase(input: "", title: ""),
        CaptureCase(input: "   ", title: ""),
        CaptureCase(input: "\n", title: ""),
        CaptureCase(input: "-", title: "-"),
        CaptureCase(input: "- ", title: "-"),
        CaptureCase(input: "1. ", title: "1."),
        CaptureCase(input: "and then", title: "Then"),
        CaptureCase(input: "!!!", title: "!!!", priority: .high),
        CaptureCase(input: "#inbox", title: "#inbox", inbox: true),
        CaptureCase(input: "  #inbox  ", title: "#inbox", inbox: true),
        CaptureCase(input: "@", title: "@"),
        CaptureCase(input: "someday", title: "someday", inbox: true),
        CaptureCase(input: "noon", title: "noon", day: "2026-11-10", remind: "2026-11-10 12:00"),
        CaptureCase(input: "at 5pm", title: "at 5pm", day: "2026-11-09", remind: "2026-11-09 17:00"),
        CaptureCase(input: "every monday", title: "every monday", repeatRule: TaskRepeat(unit: .week, weekdays: [2])),
        CaptureCase(input: "for 30 min", title: "for 30 min", minutes: 30),
        CaptureCase(input: "buy milk #inbox someday", title: "Buy milk someday", inbox: true),
    ]

    private static let detailCases: [CaptureCase] = [
        CaptureCase(input: "pay rent !!!", title: "Pay rent", priority: .high),
        CaptureCase(input: "pay rent p1", title: "Pay rent", priority: .high),
        CaptureCase(input: "pay rent p2", title: "Pay rent", priority: .medium),
        CaptureCase(input: "task p3", title: "Task", priority: .low),
        CaptureCase(input: "task !low", title: "Task", priority: .low),
        CaptureCase(input: "task !medium", title: "Task", priority: .medium),
        CaptureCase(input: "task !med", title: "Task", priority: .medium),
        CaptureCase(input: "task !urgent", title: "Task", priority: .high),
        CaptureCase(input: "pay !!! now", title: "Pay now", priority: .high),
        CaptureCase(input: "wow!!!", title: "Wow!!!"),
        CaptureCase(input: "p1x", title: "P1x"),
        CaptureCase(input: "#family", title: "#family", project: "family"),
        CaptureCase(input: "#proj-x thing", title: "Thing", project: "proj-x"),
        CaptureCase(input: "#a-b_c", title: "#a-b_c", project: "a-b_c"),
        CaptureCase(input: "#1abc", title: "#1abc"),
        CaptureCase(input: "foo#bar", title: "Foo#bar"),
        CaptureCase(input: "task for 1.5 h", title: "Task", minutes: 90),
        CaptureCase(input: "task (90m)", title: "Task", minutes: 90),
        CaptureCase(input: "task ~45m", title: "Task", minutes: 45),
        CaptureCase(input: "task for 12 hours", title: "Task", minutes: 720),
        CaptureCase(input: "task for 720 min", title: "Task", minutes: 720),
        CaptureCase(input: "task for 0 min", title: "Task"),
        CaptureCase(input: "task for 1000 min", title: "Task for 1000 min"),
        CaptureCase(input: "prep for 45 minutes", title: "Prep", minutes: 45),
        CaptureCase(input: "for 1h", title: "for 1h", minutes: 60),
        CaptureCase(input: "for 30m", title: "for 30m", minutes: 30),
        CaptureCase(input: "write tests (45m)", title: "Write tests", minutes: 45),
        CaptureCase(input: "finish report due friday", title: "Finish report", deadline: "2026-11-13"),
        CaptureCase(input: "due monday", title: "due monday", deadline: "2026-11-09"),
        CaptureCase(input: "due dec 1", title: "due dec 1", deadline: "2026-12-01"),
        CaptureCase(input: "due 2026-12-31", title: "due 2026-12-31", deadline: "2026-12-31"),
        CaptureCase(input: "due date dec 1", title: "due date dec 1", deadline: "2026-12-01"),
        CaptureCase(input: "deadline 2026-12-15", title: "deadline 2026-12-15", deadline: "2026-12-15"),
        CaptureCase(input: "deadline: nov 20", title: "deadline: nov 20", deadline: "2026-11-20"),
        CaptureCase(input: "x tomorrow due friday", title: "X", day: "2026-11-10", deadline: "2026-11-13"),
        CaptureCase(input: "x at 5pm due friday", title: "X", day: "2026-11-09", remind: "2026-11-09 17:00", deadline: "2026-11-13"),
    ]

    private static let whitespaceCases: [CaptureCase] = [
        CaptureCase(input: "  buy milk  ", title: "Buy milk"),
        CaptureCase(input: "buy milk  at  5pm", title: "Buy milk", day: "2026-11-09", remind: "2026-11-09 17:00"),
        CaptureCase(input: "buy\tmilk at 5pm", title: "Buy milk", day: "2026-11-09", remind: "2026-11-09 17:00"),
        CaptureCase(input: "- [ ] buy milk", title: "[ ] buy milk"),
        CaptureCase(input: "* then and pay rent", title: "Pay rent"),
        CaptureCase(input: "2) call mom", title: "Call mom"),
        CaptureCase(input: "BUY MILK", title: "BUY MILK"),
    ]

    // MARK: Checks

    private func check(_ c: CaptureCase, file: StaticString = #filePath, line: UInt = #line) {
        let got = cap.parse(c.input)
        let label = "input \(String(reflecting: c.input))"
        XCTAssertEqual(got.title, c.title, "title for \(label)", file: file, line: line)
        XCTAssertEqual(got.day?.raw, c.day, "day for \(label)", file: file, line: line)
        XCTAssertEqual(Fixture.hm(got.remindAt), c.remind, "reminder for \(label)", file: file, line: line)
        XCTAssertEqual(got.deadline?.raw, c.deadline, "deadline for \(label)", file: file, line: line)
        XCTAssertEqual(got.priority, c.priority, "priority for \(label)", file: file, line: line)
        XCTAssertEqual(got.projectName, c.project, "project for \(label)", file: file, line: line)
        XCTAssertEqual(got.repeatRule, c.repeatRule, "repeat for \(label)", file: file, line: line)
        XCTAssertEqual(got.minutes, c.minutes, "minutes for \(label)", file: file, line: line)
        XCTAssertEqual(got.inbox, c.inbox, "inbox for \(label)", file: file, line: line)
    }

    private func checkAll(_ cases: [CaptureCase], file: StaticString = #filePath, line: UInt = #line) {
        for c in cases { check(c, file: file, line: line) }
    }

    // MARK: Tests

    func testCorpusCoversAtLeastOneHundredFiftyPhrasings() {
        let total = Self.timeCases.count + Self.dateCases.count + Self.dayWordCases.count
            + Self.weekdayCases.count + Self.repeatCases.count + Self.unicodeCases.count
            + Self.metadataOnlyCases.count + Self.detailCases.count + Self.whitespaceCases.count
        print("TaskCaptureEdgeTests: \(total) table-driven phrasings")
        XCTAssertGreaterThanOrEqual(total, 150)
    }

    func testTimePhrasings() { checkAll(Self.timeCases) }
    func testDatePhrasingsAcrossYearEnd() { checkAll(Self.dateCases) }
    func testDayWordPhrasings() { checkAll(Self.dayWordCases) }
    func testWeekdayPhrasings() { checkAll(Self.weekdayCases) }
    func testRepeatPhrasings() { checkAll(Self.repeatCases) }
    func testUnicodeAndEmojiTitles() { checkAll(Self.unicodeCases) }
    func testEmptyAndMetadataOnlyInput() { checkAll(Self.metadataOnlyCases) }
    func testPriorityProjectDurationAndDeadlinePhrasings() { checkAll(Self.detailCases) }
    func testWhitespaceAndBullets() { checkAll(Self.whitespaceCases) }

    func testEverythingAtOnce() {
        let c = cap.parse("text dad tomorrow at 6pm !high #home every monday for 30 min due friday")
        XCTAssertEqual(c.title, "Text dad")
        XCTAssertEqual(c.day?.raw, "2026-11-10")
        XCTAssertEqual(Fixture.hm(c.remindAt), "2026-11-10 18:00")
        XCTAssertEqual(c.deadline?.raw, "2026-11-13")
        XCTAssertEqual(c.priority, .high)
        XCTAssertEqual(c.projectName, "home")
        XCTAssertEqual(c.repeatRule, TaskRepeat(unit: .week, weekdays: [2]))
        XCTAssertEqual(c.minutes, 30)
    }

    func testVeryLongTitlesSurviveParsing() {
        let long = String(repeating: "a", count: 5_000)
        let c = cap.parse(long + " at 5pm")
        XCTAssertEqual(c.title.count, 5_000)
        XCTAssertEqual(Fixture.hm(c.remindAt), "2026-11-09 17:00")

        let huge = String(repeating: "z", count: 100_000)
        XCTAssertEqual(cap.parse(huge).title.count, 100_000)
        XCTAssertEqual(cap.parse(huge + " tomorrow").day?.raw, "2026-11-10")

        let emoji = String(repeating: "🚀", count: 500)
        let e = cap.parse(emoji + " tomorrow")
        XCTAssertEqual(e.title, emoji)
        XCTAssertEqual(e.day?.raw, "2026-11-10")
    }

    func testTitleNeverGainsLeadingWhitespaceAndKeepsInteriorCasing() {
        XCTAssertEqual(cap.parse("  buy milk  ").title, "Buy milk")
        XCTAssertEqual(cap.parse("BUY MILK").title, "BUY MILK")
        XCTAssertEqual(cap.parse("call mom at 5pm").title, "Call mom")
    }

    // MARK: Bugs found by this suite (documented, not fixed here)

    func testThreeLetterWeekdaysAtEndAreParsedWithoutAPrefix() {
        // A standalone trailing abbreviation is a day, just like the full name.
        let bare = cap.parse("review sat")
        XCTAssertEqual(bare.day?.raw, "2026-11-14")
        XCTAssertEqual(bare.title, "Review")
        XCTAssertEqual(cap.parse("on sat").day?.raw, "2026-11-14")
        XCTAssertEqual(cap.parse("review saturday").day?.raw, "2026-11-14")
    }

    func testCurrencyAfterAtStaysInTitle() {
        let c = cap.parse("buy 2 apples at 3 dollars")
        XCTAssertEqual(c.title, "Buy 2 apples at 3 dollars")
        XCTAssertNil(c.remindAt)
        XCTAssertNil(c.day)
    }

    func testCurrencyAndUnitAmountsAreNotBareTimes() {
        let units = [
            "dollar", "dollars", "cent", "cents", "euro", "euros", "pound", "pounds",
            "rupee", "rupees", "yen", "USD", "EUR", "GBP", "INR",
            "gram", "grams", "kilogram", "kilograms", "kg", "lb", "lbs",
            "ounce", "ounces", "oz", "meter", "meters", "metre", "metres",
            "kilometer", "kilometers", "kilometre", "kilometres", "km", "mile", "miles",
            "liter", "liters", "litre", "litres", "ml", "page", "pages", "percent",
            "minute", "minutes", "hour", "hours", "day", "days",
        ]
        for lead in ["at ", "by ", "around ", "@"] {
            for unit in units {
                let input = "check price or quantity \(lead)3 \(unit)"
                check(CaptureCase(input: input, title: "Check price or quantity \(lead)3 \(unit)"))
            }
        }
        check(CaptureCase(input: "buy apples at 3 DOLLARS, each", title: "Buy apples at 3 DOLLARS, each"))
        check(CaptureCase(input: "buy apples at 3\tdollars", title: "Buy apples at 3 dollars"))
    }

    func testCurrencyAmountStillAllowsARealReminder() {
        for time in ["5", "5pm", "17:00"] {
            check(CaptureCase(input: "buy apples at 3 dollars at \(time)", title: "Buy apples at 3 dollars",
                              day: "2026-11-09", remind: "2026-11-09 17:00"))
        }
        // A unit prefix inside another word must not suppress an actual time.
        check(CaptureCase(input: "meet at 3 central station", title: "Meet central station",
                          day: "2026-11-10", remind: "2026-11-10 15:00"))
    }

    func testMalformedClockIsPreservedWithoutAReminder() {
        // Do not consume the hour prefix of an invalid clock.
        let c = cap.parse("call mom at 5:5")
        XCTAssertEqual(c.title, "Call mom at 5:5")
        XCTAssertNil(c.day)
        XCTAssertNil(c.remindAt)
    }

    func testImpossibleAndUnpaddedCalendarDatesAreRejected() throws {
        // Use String variables: string literals intentionally bypass the failable initializer.
        let invalid = [
            "2026-02-30", "2027-02-29", "2027-02-30", "2026-04-31", "2100-02-29",
            "2026-1-01", "2026-01-1", "2026-+1-01", "2026--01-01", "2026-01-01-",
            "2026-00-01", "2026-13-01", "2026-01-00", "2026-01-32"
        ]
        for raw in invalid {
            XCTAssertNil(DayKey(raw), raw)
        }
        for raw in ["2026-01-01", "2026-02-28", "2028-02-29", "2000-02-29", "2026-04-30"] {
            let day = try XCTUnwrap(DayKey(raw), raw)
            XCTAssertEqual(DayKey(day.date(calendar: Fixture.calendar), calendar: Fixture.calendar).raw, raw)
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perch-dates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = PlannerFile(url: dir.appendingPathComponent("planner.json"))
        let tools = AgentTools(file: file, now: { Fixture.now }, calendar: Fixture.calendar)
        let server = MCPServer(tools: tools, version: "date-regression")
        _ = try tools.call("add_tasks", ["titles": ["existing task"], "date": "2028-02-29"])
        let before = try file.load()
        for raw in invalid {
            let response = try XCTUnwrap(server.handle([
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "add_tasks", "arguments": ["titles": ["impossible"], "date": .string(raw)]]
            ]), raw)
            XCTAssertEqual(response["result"]?["isError"]?.bool, true, raw)
            XCTAssertTrue(response["result"]?["content"]?.array?.first?["text"]?.string?.contains("yyyy-MM-dd") ?? false, raw)
            XCTAssertEqual(try file.load(), before, "Invalid date must not mutate the planner: \(raw)")
        }
    }

    func testMetadataOnlyLinesPreserveRawTrimmedTitles() throws {
        let inputs = ["due", "for", "at", "and", "by", "until", "on", "around", "-", ",", ";", ":",
                      "  DuE \t", "  at   5pm  ", "  #family  ", "  every monday  "]
        var e = PlannerEngine(planner: Planner(), now: { Fixture.now }, calendar: Fixture.calendar)
        for input in inputs {
            let expected = input.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(cap.parse(input).title, expected, "input: \(input)")
            let added = try e.addTasks([input])
            XCTAssertEqual(added.map(\.title), [expected], "input: \(input)")
        }
        XCTAssertEqual(e.planner.tasks.map(\.title), inputs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        XCTAssertTrue(e.planner.tasks.allSatisfy { !$0.title.isEmpty })
    }

    func testEmptyTaskInputIsRejectedWithoutAddingTasks() {
        for literal in [false, true] {
            for input in ["", " ", "\t", "\r\n", " \u{00a0}\n"] {
                var e = PlannerEngine(planner: Planner(), now: { Fixture.now }, calendar: Fixture.calendar)
                XCTAssertEqual(cap.parse(input).title, "")
                XCTAssertThrowsError(try e.addTasks([input], literal: literal)) { error in
                    XCTAssertEqual(error.localizedDescription, "Add at least one task title with text.")
                }
                XCTAssertTrue(e.planner.tasks.isEmpty)
            }
        }
    }

    func testFebTwentyNinthResolvesToNextLeapYear() {
        // Yearless leap-day capture must find a real future Feb 29.
        let c = cap.parse("plan feb 29")
        XCTAssertEqual(c.day?.raw, "2028-02-29")
        XCTAssertEqual(c.title, "Plan")
        XCTAssertEqual(cap.parse("plan feb 29 2028").day?.raw, "2028-02-29")
    }

    func testBUG_RepeatedInboxTokenSurvivesInTitle() {
        // BUG: only the first occurrence of a metadata token is stripped, so the
        // second inbox marker stays in the title.
        // Repro: cap.parse("buy milk #inbox someday").title == "Buy milk someday".
        let c = cap.parse("buy milk #inbox someday")
        XCTAssertTrue(c.inbox)
        XCTAssertEqual(c.title, "Buy milk someday")
    }

    // MARK: DST in America/Los_Angeles

    func testSpringForwardDoesNotCrashOrShiftTheDay() {
        let cal = Fixture.calendar
        let cap = TaskCapture(now: Fixture.date("2027-03-13 12:00"), calendar: cal)
        // 2027-03-14 02:30 does not exist; Foundation maps it to 03:00 PDT.
        let missing = cap.parse("x march 14 at 2:30am")
        XCTAssertEqual(missing.day?.raw, "2027-03-14")
        XCTAssertEqual(Fixture.hm(missing.remindAt), "2027-03-14 03:00")

        let before = cap.parse("x march 14 at 1:30am")
        XCTAssertEqual(Fixture.hm(before.remindAt), "2027-03-14 01:30")
        let after = cap.parse("x march 14 at 3:30am")
        XCTAssertEqual(Fixture.hm(after.remindAt), "2027-03-14 03:30")

        var e = PlannerEngine(planner: Planner(), now: { Fixture.date("2027-03-13 12:00") }, calendar: cal)
        XCTAssertEqual(Fixture.hm(try e.parseReminder("2:30 am", on: "2027-03-14")), "2027-03-14 03:00")
    }

    func testFallBackOneThirtyStaysOnTheRightDay() {
        let cap = TaskCapture(now: Fixture.date("2026-10-31 12:00"), calendar: Fixture.calendar)
        let c = cap.parse("x nov 1 at 1:30am")
        XCTAssertEqual(c.day?.raw, "2026-11-01")
        XCTAssertEqual(Fixture.hm(c.remindAt), "2026-11-01 01:30")
        // 01:30 happens twice that day; either offset is a correct reading.
        let epoch = c.remindAt?.timeIntervalSince1970
        XCTAssertTrue(epoch == 1_793_521_800 || epoch == 1_793_525_400, "\(epoch ?? -1)")
    }

    func testDayArithmeticIsCalendarBasedAcrossDST() {
        let cal = Fixture.calendar
        XCTAssertEqual(DayKey("2027-03-13").adding(days: 1, calendar: cal).raw, "2027-03-14")
        XCTAssertEqual(DayKey("2026-10-31").adding(days: 1, calendar: cal).raw, "2026-11-01")
        // Spring-forward day is 23 h long, fall-back day is 25 h.
        let spring = DayKey("2027-03-15").date(calendar: cal).timeIntervalSince(DayKey("2027-03-14").date(calendar: cal))
        let fall = DayKey("2026-11-02").date(calendar: cal).timeIntervalSince(DayKey("2026-11-01").date(calendar: cal))
        XCTAssertEqual(spring, 23 * 3600, accuracy: 1)
        XCTAssertEqual(fall, 25 * 3600, accuracy: 1)
    }
}
