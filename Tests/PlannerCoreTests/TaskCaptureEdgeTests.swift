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
        CaptureCase(input: "call mom at 5pm", title: "call mom", day: "2026-11-09", remind: "2026-11-09 17:00"),
        CaptureCase(input: "call mom at 5 pm", title: "call mom", day: "2026-11-09", remind: "2026-11-09 17:00"),
        CaptureCase(input: "call mom at 5pm.", title: "call mom", day: "2026-11-09", remind: "2026-11-09 17:00"),
        CaptureCase(input: "call mom 5pm", title: "call mom", day: "2026-11-09", remind: "2026-11-09 17:00"),
        CaptureCase(input: "call mom @5pm", title: "call mom", day: "2026-11-09", remind: "2026-11-09 17:00"),
        CaptureCase(input: "call mom at 17:30", title: "call mom", day: "2026-11-09", remind: "2026-11-09 17:30"),
        CaptureCase(input: "call mom at 5:30", title: "call mom", day: "2026-11-09", remind: "2026-11-09 17:30"),
        CaptureCase(input: "call mom at 12am", title: "call mom", day: "2026-11-10", remind: "2026-11-10 00:00"),
        CaptureCase(input: "call mom at 12 pm", title: "call mom", day: "2026-11-10", remind: "2026-11-10 12:00"),
        CaptureCase(input: "call mom at 12:30am", title: "call mom", day: "2026-11-10", remind: "2026-11-10 00:30"),
        CaptureCase(input: "call mom at noon", title: "call mom", day: "2026-11-10", remind: "2026-11-10 12:00"),
        CaptureCase(input: "call mom at midnight", title: "call mom", day: "2026-11-10", remind: "2026-11-10 00:00"),
        CaptureCase(input: "call mom at midday", title: "call mom", day: "2026-11-10", remind: "2026-11-10 12:00"),
        CaptureCase(input: "call mom around 6pm", title: "call mom", day: "2026-11-09", remind: "2026-11-09 18:00"),
        CaptureCase(input: "call mom by 6pm", title: "call mom", day: "2026-11-09", remind: "2026-11-09 18:00"),
        CaptureCase(input: "call mom at 9", title: "call mom", day: "2026-11-10", remind: "2026-11-10 09:00"),
        CaptureCase(input: "call mom at 21", title: "call mom", day: "2026-11-09", remind: "2026-11-09 21:00"),
        CaptureCase(input: "call mom at 0", title: "call mom", day: "2026-11-10", remind: "2026-11-10 00:00"),
        CaptureCase(input: "call mom at 23:59", title: "call mom", day: "2026-11-09", remind: "2026-11-09 23:59"),
        CaptureCase(
            input: "call mom at 5pm tomorrow", title: "call mom", day: "2026-11-10", remind: "2026-11-10 17:00"),
        CaptureCase(input: "read at 5 pages", title: "read at 5 pages"),
        CaptureCase(input: "meeting at 1", title: "meeting", day: "2026-11-10", remind: "2026-11-10 13:00"),
        CaptureCase(input: "at 8", title: "at 8", day: "2026-11-10", remind: "2026-11-10 08:00"),
        CaptureCase(input: "call at 8pm tomorrow", title: "call", day: "2026-11-10", remind: "2026-11-10 20:00"),
        CaptureCase(input: "lunch tomorrow noon", title: "lunch", day: "2026-11-10", remind: "2026-11-10 12:00"),
        CaptureCase(input: "x 5:30am", title: "x", day: "2026-11-10", remind: "2026-11-10 05:30"),
        CaptureCase(input: "x at 12:00", title: "x", day: "2026-11-10", remind: "2026-11-10 12:00"),
        CaptureCase(input: "x 12:00pm", title: "x", day: "2026-11-10", remind: "2026-11-10 12:00"),
        CaptureCase(input: "x at 00:00", title: "x", day: "2026-11-10", remind: "2026-11-10 00:00"),
        CaptureCase(input: "x at 24:00", title: "x at 24:00"),
        CaptureCase(input: "x at 19:30", title: "x", day: "2026-11-09", remind: "2026-11-09 19:30"),
        CaptureCase(input: "call mom at 5 P.M.", title: "call mom", day: "2026-11-09", remind: "2026-11-09 17:00"),
        CaptureCase(input: "call mom at 5 p.m", title: "call mom", day: "2026-11-09", remind: "2026-11-09 17:00"),
        CaptureCase(input: "Call Mom at 5PM", title: "Call Mom", day: "2026-11-09", remind: "2026-11-09 17:00"),
        CaptureCase(input: "x at 7:00am", title: "x", day: "2026-11-10", remind: "2026-11-10 07:00"),
        CaptureCase(
            input: "dentist at 10am on friday", title: "dentist", day: "2026-11-13", remind: "2026-11-13 10:00"),
        CaptureCase(input: "vet on friday at 10", title: "vet", day: "2026-11-13", remind: "2026-11-13 10:00"),
        CaptureCase(input: "on Friday standup at 9", title: "standup", day: "2026-11-13", remind: "2026-11-13 09:00"),
        CaptureCase(input: "on SUNDAY brunch at 11am", title: "brunch", day: "2026-11-15", remind: "2026-11-15 11:00"),
    ]

    private static let dateCases: [CaptureCase] = [
        CaptureCase(input: "new year jan 1", title: "new year", day: "2027-01-01"),
        CaptureCase(input: "party dec 31", title: "party", day: "2026-12-31"),
        CaptureCase(input: "party dec 31 2026", title: "party", day: "2026-12-31"),
        CaptureCase(input: "party jan 1 2027", title: "party", day: "2027-01-01"),
        CaptureCase(input: "review sep 1", title: "review", day: "2027-09-01"),
        CaptureCase(input: "review september 1st", title: "review", day: "2027-09-01"),
        CaptureCase(input: "review 1st of september", title: "review", day: "2027-09-01"),
        CaptureCase(input: "review on the 15th", title: "review", day: "2026-11-15"),
        CaptureCase(input: "review on the 31st", title: "review", day: "2026-12-31"),
        CaptureCase(input: "plan feb 28", title: "plan", day: "2027-02-28"),
        CaptureCase(input: "plan feb 29 2028", title: "plan", day: "2028-02-29"),
        CaptureCase(input: "plan mar 1", title: "plan", day: "2027-03-01"),
        CaptureCase(input: "x dec 31 at 11:59pm", title: "x", day: "2026-12-31", remind: "2026-12-31 23:59"),
        CaptureCase(input: "party dec 31 at 8pm", title: "party", day: "2026-12-31", remind: "2026-12-31 20:00"),
        CaptureCase(input: "x nov 30 at 11:59pm", title: "x", day: "2026-11-30", remind: "2026-11-30 23:59"),
        CaptureCase(input: "x 2026-12-31", title: "x", day: "2026-12-31"),
        CaptureCase(input: "x 2027-01-01 at 00:30", title: "x", day: "2027-01-01", remind: "2027-01-01 00:30"),
        CaptureCase(input: "x 2028-02-29", title: "x", day: "2028-02-29"),
        CaptureCase(input: "x 2026-13-01", title: "x 2026-13-01"),
        CaptureCase(input: "x feb 28 2028", title: "x", day: "2028-02-28"),
        CaptureCase(input: "x sep 30", title: "x", day: "2027-09-30"),
        CaptureCase(input: "tax prep apr 15", title: "tax prep", day: "2027-04-15"),
        CaptureCase(input: "renew passport on the 3rd", title: "renew passport", day: "2026-12-03"),
        CaptureCase(input: "x december 31st", title: "x", day: "2026-12-31"),
        CaptureCase(input: "x Dec. 31", title: "x", day: "2026-12-31"),
        CaptureCase(input: "x on the 1st", title: "x", day: "2026-12-01"),
        CaptureCase(input: "call bank in 3 days", title: "call bank", day: "2026-11-12"),
        CaptureCase(input: "plan trip in 2 weeks", title: "plan trip", day: "2026-11-23"),
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
        CaptureCase(input: "x tomorrow at 12am", title: "x", day: "2026-11-10", remind: "2026-11-10 00:00"),
    ]

    private static let weekdayCases: [CaptureCase] = [
        CaptureCase(input: "x on monday", title: "x", day: "2026-11-09"),
        CaptureCase(input: "x this monday", title: "x", day: "2026-11-09"),
        CaptureCase(input: "x next monday", title: "x", day: "2026-11-16"),
        CaptureCase(input: "on thu", title: "on thu", day: "2026-11-12"),
        CaptureCase(input: "x on friday", title: "x", day: "2026-11-13"),
        CaptureCase(input: "x this friday", title: "x", day: "2026-11-13"),
        CaptureCase(input: "x next friday", title: "x", day: "2026-11-20"),
        CaptureCase(input: "x next friday at 10am", title: "x", day: "2026-11-20", remind: "2026-11-20 10:00"),
        CaptureCase(input: "x on saturday", title: "x", day: "2026-11-14"),
        CaptureCase(input: "x on sunday", title: "x", day: "2026-11-15"),
        CaptureCase(input: "x next sunday", title: "x", day: "2026-11-22"),
    ]

    private static let repeatCases: [CaptureCase] = [
        CaptureCase(input: "gym every monday", title: "gym", repeatRule: TaskRepeat(unit: .week, weekdays: [2])),
        CaptureCase(
            input: "gym every mon, wed and fri", title: "gym", repeatRule: TaskRepeat(unit: .week, weekdays: [2, 4, 6])),
        CaptureCase(input: "gym every mon & wed", title: "gym", repeatRule: TaskRepeat(unit: .week, weekdays: [2, 4])),
        CaptureCase(
            input: "gym every tuesday, thursday", title: "gym", repeatRule: TaskRepeat(unit: .week, weekdays: [3, 5])),
        CaptureCase(input: "gym every tues", title: "gym", repeatRule: TaskRepeat(unit: .week, weekdays: [3])),
        CaptureCase(input: "gym every thurs", title: "gym", repeatRule: TaskRepeat(unit: .week, weekdays: [5])),
        CaptureCase(input: "gym every sun, sat", title: "gym", repeatRule: TaskRepeat(unit: .week, weekdays: [1, 7])),
        CaptureCase(
            input: "gym every other tuesday", title: "gym",
            repeatRule: TaskRepeat(unit: .week, interval: 2, weekdays: [3])),
        CaptureCase(
            input: "1:1 every other week on tue", title: "1:1",
            repeatRule: TaskRepeat(unit: .week, interval: 2, weekdays: [3])),
        CaptureCase(input: "gym every other day", title: "gym", repeatRule: TaskRepeat(unit: .day, interval: 2)),
        CaptureCase(input: "gym every other week", title: "gym", repeatRule: TaskRepeat(unit: .week, interval: 2)),
        CaptureCase(input: "gym every 2 weeks", title: "gym", repeatRule: TaskRepeat(unit: .week, interval: 2)),
        CaptureCase(input: "gym every week", title: "gym", repeatRule: .weekly),
        CaptureCase(input: "gym daily", title: "gym daily"),
        CaptureCase(input: "gym weekly", title: "gym weekly"),
        CaptureCase(input: "gym monthly", title: "gym monthly"),
        CaptureCase(input: "gym every month", title: "gym", repeatRule: .monthly),
        CaptureCase(input: "gym every 3 months", title: "gym", repeatRule: TaskRepeat(unit: .month, interval: 3)),
        CaptureCase(
            input: "gym every! 3 days", title: "gym",
            repeatRule: TaskRepeat(unit: .day, interval: 3, fromCompletion: true)),
        CaptureCase(input: "gym weekdays", title: "gym weekdays"),
        CaptureCase(input: "gym every weekday", title: "gym", repeatRule: .weekdaysRule),
    ]

    private static let unicodeCases: [CaptureCase] = [
        CaptureCase(input: "🏋️ gym tomorrow at 7am", title: "🏋️ gym", day: "2026-11-10", remind: "2026-11-10 07:00"),
        CaptureCase(
            input: "café ☕ with Ana at 10am", title: "café ☕ with Ana", day: "2026-11-10", remind: "2026-11-10 10:00"),
        CaptureCase(input: "日本語のタスク tomorrow", title: "日本語のタスク", day: "2026-11-10"),
        CaptureCase(input: "call 妈妈明天", title: "call 妈妈明天"),
        CaptureCase(input: "pay ₹500 !high", title: "pay ₹500", priority: .high),
        CaptureCase(input: "naïve résumé review", title: "naïve résumé review"),
        CaptureCase(
            input: "👨‍👩‍👧‍👦 family dinner at 6pm", title: "👨‍👩‍👧‍👦 family dinner", day: "2026-11-09", remind: "2026-11-09 18:00"),
        CaptureCase(input: "🎉", title: "🎉"),
    ]

    private static let metadataOnlyCases: [CaptureCase] = [
        CaptureCase(input: "", title: ""),
        CaptureCase(input: "   ", title: ""),
        CaptureCase(input: "\n", title: ""),
        CaptureCase(input: "-", title: "-"),
        CaptureCase(input: "- ", title: "-"),
        CaptureCase(input: "1. ", title: "1."),
        CaptureCase(input: "and then", title: "and then"),
        CaptureCase(input: "!!!", title: "!!!", priority: .high),
        CaptureCase(input: "#inbox", title: "#inbox", inbox: true),
        CaptureCase(input: "  #inbox  ", title: "#inbox", inbox: true),
        CaptureCase(input: "@", title: "@"),
        CaptureCase(input: "someday", title: "someday", inbox: true),
        CaptureCase(input: "noon", title: "noon", day: "2026-11-10", remind: "2026-11-10 12:00"),
        CaptureCase(input: "at 5pm", title: "at 5pm", day: "2026-11-09", remind: "2026-11-09 17:00"),
        CaptureCase(input: "every monday", title: "every monday", repeatRule: TaskRepeat(unit: .week, weekdays: [2])),
        CaptureCase(input: "for 30 min", title: "for 30 min", minutes: 30),
        CaptureCase(input: "buy milk #inbox someday", title: "buy milk someday", inbox: true),
    ]

    private static let detailCases: [CaptureCase] = [
        CaptureCase(input: "pay rent !!!", title: "pay rent", priority: .high),
        CaptureCase(input: "pay rent p1", title: "pay rent p1"),
        CaptureCase(input: "pay rent p2", title: "pay rent p2"),
        CaptureCase(input: "task p3", title: "task p3"),
        CaptureCase(input: "task !low", title: "task", priority: .low),
        CaptureCase(input: "task !medium", title: "task", priority: .medium),
        CaptureCase(input: "task !med", title: "task", priority: .medium),
        CaptureCase(input: "task !urgent", title: "task", priority: .high),
        CaptureCase(input: "pay !!! now", title: "pay now", priority: .high),
        CaptureCase(input: "wow!!!", title: "wow!!!"),
        CaptureCase(input: "p1x", title: "p1x"),
        CaptureCase(input: "#family", title: "#family", project: "family"),
        CaptureCase(input: "#proj-x thing", title: "thing", project: "proj-x"),
        CaptureCase(input: "#a-b_c", title: "#a-b_c", project: "a-b_c"),
        CaptureCase(input: "#1abc", title: "#1abc"),
        CaptureCase(input: "foo#bar", title: "foo#bar"),
        CaptureCase(input: "task for 1.5 h", title: "task", minutes: 90),
        CaptureCase(input: "task (90m)", title: "task", minutes: 90),
        CaptureCase(input: "task ~45m", title: "task", minutes: 45),
        CaptureCase(input: "task for 12 hours", title: "task", minutes: 720),
        CaptureCase(input: "task for 720 min", title: "task", minutes: 720),
        CaptureCase(input: "task for 0 min", title: "task"),
        CaptureCase(input: "task for 1000 min", title: "task for 1000 min"),
        CaptureCase(input: "prep for 45 minutes", title: "prep", minutes: 45),
        CaptureCase(input: "for 1h", title: "for 1h", minutes: 60),
        CaptureCase(input: "for 30m", title: "for 30m", minutes: 30),
        CaptureCase(input: "write tests (45m)", title: "write tests", minutes: 45),
        CaptureCase(input: "finish report due friday", title: "finish report", deadline: "2026-11-13"),
        CaptureCase(input: "due monday", title: "due monday", deadline: "2026-11-09"),
        CaptureCase(input: "due dec 1", title: "due dec 1", deadline: "2026-12-01"),
        CaptureCase(input: "due 2026-12-31", title: "due 2026-12-31", deadline: "2026-12-31"),
        CaptureCase(input: "due date dec 1", title: "due date dec 1", deadline: "2026-12-01"),
        CaptureCase(input: "deadline 2026-12-15", title: "deadline 2026-12-15", deadline: "2026-12-15"),
        CaptureCase(input: "deadline: nov 20", title: "deadline: nov 20", deadline: "2026-11-20"),
        CaptureCase(input: "x tomorrow due friday", title: "x", day: "2026-11-10", deadline: "2026-11-13"),
        CaptureCase(
            input: "x at 5pm due friday", title: "x", day: "2026-11-09", remind: "2026-11-09 17:00",
            deadline: "2026-11-13"),
    ]

    private static let whitespaceCases: [CaptureCase] = [
        CaptureCase(input: "  buy milk  ", title: "buy milk"),
        CaptureCase(input: "buy milk  at  5pm", title: "buy milk", day: "2026-11-09", remind: "2026-11-09 17:00"),
        CaptureCase(input: "buy\tmilk at 5pm", title: "buy\tmilk", day: "2026-11-09", remind: "2026-11-09 17:00"),
        CaptureCase(input: "- [ ] buy milk", title: "[ ] buy milk"),
        CaptureCase(input: "* then and pay rent", title: "pay rent"),
        CaptureCase(input: "2) call mom", title: "call mom"),
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
        let total =
            Self.timeCases.count + Self.dateCases.count + Self.dayWordCases.count
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
        XCTAssertEqual(c.title, "text dad")
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
        XCTAssertEqual(cap.parse("  buy milk  ").title, "buy milk")
        XCTAssertEqual(cap.parse("BUY MILK").title, "BUY MILK")
        XCTAssertEqual(cap.parse("call mom at 5pm").title, "call mom")
    }

    // MARK: Boundary regressions

    func testWeekdaysNeedAnExplicitPrefix() {
        for input in ["review sat", "review saturday"] {
            let bare = cap.parse(input)
            XCTAssertNil(bare.day)
            XCTAssertEqual(bare.title, input)
        }
        XCTAssertEqual(cap.parse("on sat").day?.raw, "2026-11-14")
        XCTAssertEqual(cap.parse("review on saturday").day?.raw, "2026-11-14")
    }

    func testCurrencyAfterAtStaysInTitle() {
        let c = cap.parse("buy 2 apples at 3 dollars")
        XCTAssertEqual(c.title, "buy 2 apples at 3 dollars")
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
                check(CaptureCase(input: input, title: "check price or quantity \(lead)3 \(unit)"))
            }
        }
        check(CaptureCase(input: "buy apples at 3 DOLLARS, each", title: "buy apples at 3 DOLLARS, each"))
        check(CaptureCase(input: "buy apples at 3\tdollars", title: "buy apples at 3\tdollars"))
    }

    func testCurrencyAmountStillAllowsARealReminder() {
        for time in ["5", "5pm", "17:00"] {
            check(
                CaptureCase(
                    input: "buy apples at 3 dollars at \(time)", title: "buy apples at 3 dollars",
                    day: "2026-11-09", remind: "2026-11-09 17:00"))
        }
        // A unit prefix inside another word must not suppress an actual time.
        check(
            CaptureCase(
                input: "meet at 3 central station", title: "meet central station",
                day: "2026-11-10", remind: "2026-11-10 15:00"))
    }

    func testMalformedClockIsPreservedWithoutAReminder() {
        // Do not consume the hour prefix of an invalid clock.
        let c = cap.parse("call mom at 5:5")
        XCTAssertEqual(c.title, "call mom at 5:5")
        XCTAssertNil(c.day)
        XCTAssertNil(c.remindAt)
    }

    func testImpossibleAndUnpaddedCalendarDatesAreRejected() throws {
        // Use String variables: string literals intentionally bypass the failable initializer.
        let invalid = [
            "2026-02-30", "2027-02-29", "2027-02-30", "2026-04-31", "2100-02-29",
            "2026-1-01", "2026-01-1", "2026-+1-01", "2026--01-01", "2026-01-01-",
            "2026-00-01", "2026-13-01", "2026-01-00", "2026-01-32",
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
            let response = try XCTUnwrap(
                server.handle([
                    "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                    "params": ["name": "add_tasks", "arguments": ["titles": ["impossible"], "date": .string(raw)]],
                ]), raw)
            XCTAssertEqual(response["result"]?["isError"]?.bool, true, raw)
            XCTAssertTrue(
                response["result"]?["content"]?.array?.first?["text"]?.string?.contains("yyyy-MM-dd") ?? false, raw)
            XCTAssertEqual(try file.load(), before, "Invalid date must not mutate the planner: \(raw)")
        }
    }

    func testMetadataOnlyLinesPreserveRawTrimmedTitles() throws {
        let inputs = [
            "due", "for", "at", "and", "by", "until", "on", "around", "-", ",", ";", ":",
            "  DuE \t", "  at   5pm  ", "  #family  ", "  every monday  ",
        ]
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
        XCTAssertEqual(c.title, "plan")
        XCTAssertEqual(cap.parse("plan feb 29 2028").day?.raw, "2028-02-29")
    }

    func testBUG_RepeatedInboxTokenSurvivesInTitle() {
        // BUG: only the first occurrence of a metadata token is stripped, so the
        // second inbox marker stays in the title.
        // Repro: cap.parse("buy milk #inbox someday").title == "buy milk someday".
        let c = cap.parse("buy milk #inbox someday")
        XCTAssertTrue(c.inbox)
        XCTAssertEqual(c.title, "buy milk someday")
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
        let spring = DayKey("2027-03-15").date(calendar: cal).timeIntervalSince(
            DayKey("2027-03-14").date(calendar: cal))
        let fall = DayKey("2026-11-02").date(calendar: cal).timeIntervalSince(DayKey("2026-11-01").date(calendar: cal))
        XCTAssertEqual(spring, 23 * 3600, accuracy: 1)
        XCTAssertEqual(fall, 25 * 3600, accuracy: 1)
    }
}
