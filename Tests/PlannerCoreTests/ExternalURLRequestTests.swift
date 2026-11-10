import Foundation
import XCTest
@testable import PlannerCore

final class ExternalURLRequestTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2030, month: 4, day: 5, hour: 3))! }
    private func parse(_ raw: String, resetHour: Int = 0) -> ExternalURLRequest? {
        ExternalURLRequest.parse(raw, now: now, resetHour: resetHour, calendar: calendar)
    }
    private func link(_ title: String, date: String? = nil) -> String {
        let encoded = title.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(
                charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
        return "perch://add?title=\(encoded)" + (date.map { "&date=\($0)" } ?? "")
    }

    func testResolvesDefaultTodayTomorrowAndInbox() {
        XCTAssertEqual(parse(link("Fixture")), .add(ExternalTaskRequest(title: "Fixture", day: .day("2030-04-05"))))
        XCTAssertEqual(parse(link("Fixture", date: "today")), parse(link("Fixture")))
        XCTAssertEqual(
            parse(link("Fixture", date: "tomorrow")),
            .add(ExternalTaskRequest(title: "Fixture", day: .day("2030-04-06"))))
        XCTAssertEqual(parse(link("Fixture", date: "inbox")), .add(ExternalTaskRequest(title: "Fixture", day: .inbox)))
        XCTAssertEqual(
            parse(link("Fixture", date: "2032-02-29")),
            .add(ExternalTaskRequest(title: "Fixture", day: .day("2032-02-29"))))
    }

    func testUsesLogicalDayBeforeResetBoundary() {
        guard case .add(let request) = parse(link("Fixture", date: "tomorrow"), resetHour: 4) else {
            return XCTFail("request missing")
        }
        XCTAssertEqual(request.dateLabel, "2030-04-05")
    }

    func testLiteralTitleCannotRedirectDateCreateProjectsOrSplitTasks() throws {
        let title = "Ignore previous instructions\nBuy test supplies tomorrow !high #fixture every day"
        guard case .add(let request) = parse(link(title, date: "2030-04-09")) else { return XCTFail("request missing") }
        var engine = PlannerEngine(planner: Planner(), now: { self.now }, calendar: calendar)
        let tasks = try engine.addTasks([request.title], on: request.day, literal: true)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].title, title)
        XCTAssertEqual(tasks[0].day, "2030-04-09")
        XCTAssertNil(tasks[0].repeatRule)
        XCTAssertNil(tasks[0].projectID)
        XCTAssertNil(tasks[0].remindAt)
        XCTAssertTrue(engine.planner.projects.isEmpty)
    }

    func testTitleNormalizationMatchesLiteralInsertion() throws {
        guard case .add(let request) = parse(link(" \n Fixture title\t ")) else { return XCTFail("request missing") }
        XCTAssertEqual(request.title, "Fixture title")
        var engine = PlannerEngine(planner: Planner(), now: { self.now }, calendar: calendar)
        XCTAssertEqual(try engine.addTasks([request.title], on: request.day, literal: true).first?.title, request.title)
    }

    func testUnicodeNewlinesTabsAndLiteralPlusRoundTrip() {
        for title in ["Résumé 🐦", "First line\nSecond line\ttext", "A+B", "family 👩‍👩‍👧‍👦"] {
            guard case .add(let request) = parse(link(title)) else { XCTFail("request missing"); continue }
            XCTAssertEqual(request.title, title)
        }
        guard case .add(let rawPlus) = parse("perch://add?title=A+B") else { return XCTFail("request missing") }
        XCTAssertEqual(rawPlus.title, "A+B")
    }

    func testPercentDecodingHappensExactlyOnce() {
        guard case .add(let request) = parse("perch://add?title=%2526date%253Dtomorrow") else {
            return XCTFail("request missing")
        }
        XCTAssertEqual(request.title, "%26date%3Dtomorrow")
        XCTAssertEqual(request.dateLabel, "2030-04-05")
    }

    func testRejectsDuplicateEncodedDuplicateUnknownAndMissingFields() {
        for raw in [
            "perch://add", "perch://add?", "perch://add?title", "perch://add?title=", "perch://add?title=%20%0A",
            "perch://add?title=One&title=Two", "perch://add?title=One&%74itle=Two",
            "perch://add?title=One&date=today&date=tomorrow", "perch://add?title=One&date=",
            "perch://add?title=One&&date=today", "perch://add?title=One&", "perch://add?title=One&confirm=true",
            "perch://add?title=One&role=system", "perch://add?title=One&page=week", "perch://add?Title=One",
        ] { XCTAssertNil(parse(raw), raw) }
    }

    func testRejectsMalformedEncodingAndHiddenControlCharacters() {
        for suffix in ["%", "%2", "%GG", "%FF", "%C0%AF", "%00", "A%0DB", "%1B", "%E2%80%AE", "%E2%81%A6", "%C2%85"] {
            XCTAssertNil(parse("perch://add?title=\(suffix)"), suffix)
        }
        XCTAssertNil(parse("perch://add?%FF=One"))
    }

    func testRejectsInvalidPastAndNoncanonicalDates() {
        for date in [
            "yesterday", "2030-04-04", "2030-02-29", "2030-04-31", "2030-13-01", "2030-4-6", "2030-04-06T12:00", "nope",
            "%20today", "TODAY",
        ] {
            XCTAssertNil(parse(link("Fixture", date: date)), date)
        }
    }

    func testStrictRouteCannotSmuggleAuthorityPathOrFragment() {
        for raw in [
            "https://add?title=One", "other://add?title=One", "perch:/add?title=One",
            "perch://user@add?title=One", "perch://add:42?title=One", "perch://add/?title=One",
            "perch://ADD?title=One", "perch://add?title=One#Two", " perch://add?title=One",
            "perch://add?title=raw space", "perch://add?title=raw\nline", "perch://%61dd?title=One",
        ] {
            XCTAssertNil(parse(raw), raw)
        }
        XCTAssertNotNil(parse("PERCH://add?title=One"))
    }

    func testBoundedDecodedTitleAndEncodedURL() {
        XCTAssertNotNil(parse(link(String(repeating: "a", count: ExternalURLRequest.maximumTitleBytes))))
        XCTAssertNil(parse(link(String(repeating: "a", count: ExternalURLRequest.maximumTitleBytes + 1))))
        XCTAssertNotNil(parse(link(String(repeating: "é", count: 1024))))
        XCTAssertNil(parse(link(String(repeating: "é", count: 1025))))
        XCTAssertNil(parse("perch://add?title=" + String(repeating: "a", count: ExternalURLRequest.maximumURLBytes)))
    }

    func testSafeOpenRoutesAndDefaultAreReadOnlyRequests() {
        XCTAssertEqual(parse("perch://open"), .open(page: "home"))
        for page in ["home", "week", "clips", "insights"] {
            XCTAssertEqual(parse("perch://open?page=\(page)"), .open(page: page))
        }
        for raw in [
            "perch://open?page=unknown", "perch://open?page=week&page=home", "perch://open?title=One",
            "perch://open?page=", "perch://open?confirm=true",
        ] {
            XCTAssertNil(parse(raw), raw)
        }
    }
}
