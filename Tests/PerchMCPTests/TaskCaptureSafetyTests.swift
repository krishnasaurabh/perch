import PlannerTestSupport
import XCTest
@testable import PlannerCore
@testable import PerchMCP

final class TaskCaptureSafetyTests: XCTestCase {
    private let capture = Fixture.capture
    private let literalTitles = [
        "Finish weekly report", "Review P1 bugs", "Hang laundry in the sun",
        "Black Friday shopping list", "Read John 3:16", "iPhone screen repair",
    ]

    private func assertLiteral(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(capture.parse(title), CapturedTask(title: title), file: file, line: line)
    }

    func testSixOrdinaryTitlesStayLiteral() {
        for title in literalTitles { assertLiteral(title) }
    }

    func testAmbiguousWordsNeverBecomeMetadata() {
        for title in [
            "daily journal", "weekly report", "monthly totals", "weekdays at home",
            "review p1", "review p2", "review p3", "we sat", "watch the sun",
            "Friday shopping", "shopping Friday", "a Monday in winter",
            "notes 12:30", "then review", "research and", "version: beta;",
            "iPhone  screen repair", "café\tnotes",
        ] {
            assertLiteral(title)
        }
        XCTAssertNil(TaskRepeat.find(in: "weekly report"))
        // Standalone repeat fields remain compatible with their existing aliases.
        XCTAssertEqual(TaskRepeat.parseRule("weekly")!!, .weekly)
        XCTAssertEqual(TaskRepeat.parseRule("daily")!!, .daily)
        XCTAssertEqual(TaskRepeat.parseRule("monthly")!!, .monthly)
        XCTAssertEqual(TaskRepeat.parseRule("weekdays")!!, .weekdaysRule)
    }

    func testExplicitMetadataStillWorksWithoutChangingTitleCase() {
        let c = capture.parse("iPhone repair tomorrow at 6pm !high #devices every Monday for 25 min due Friday")
        XCTAssertEqual(c.title, "iPhone repair")
        XCTAssertEqual(c.day?.raw, "2026-11-10")
        XCTAssertEqual(Fixture.hm(c.remindAt), "2026-11-10 18:00")
        XCTAssertEqual(c.deadline?.raw, "2026-11-13")
        XCTAssertEqual(c.priority, .high)
        XCTAssertEqual(c.projectName, "devices")
        XCTAssertEqual(c.repeatRule, TaskRepeat(unit: .week, weekdays: [2]))
        XCTAssertEqual(c.minutes, 25)
        for phrase in ["on Friday", "this Friday", "on fri"] {
            XCTAssertEqual(capture.parse("repair \(phrase)").day?.raw, "2026-11-13")
        }
        XCTAssertEqual(capture.parse("repair next Friday").day?.raw, "2026-11-20")
        XCTAssertEqual(capture.parse("repair 2026-12-01 at 17:30").day?.raw, "2026-12-01")
        XCTAssertEqual(Fixture.hm(capture.parse("repair at 17:30").remindAt), "2026-11-09 17:30")
    }

    func testQuotedSegmentsAreOpaqueAndPreservedExactly() {
        for title in [
            #""tomorrow at 6pm !high #devices every Monday""#,
            "‘tomorrow’", "“every Monday”", "'on Friday'",
            #"repair "iPhone  screen\t!high""#,
            "don't capitalize", "review ‘tomorrow and !high’",
        ] {
            assertLiteral(title)
        }
        let c = capture.parse(#"read "John 3:16 tomorrow" tomorrow !high"#)
        XCTAssertEqual(c.title, #"read "John 3:16 tomorrow""#)
        XCTAssertEqual(c.day?.raw, "2026-11-10")
        XCTAssertEqual(c.priority, .high)
        XCTAssertNil(c.remindAt)
        assertLiteral(#"read "tomorrow !high"#)  // Unclosed quote protects the remaining text.
        assertLiteral(#"read "an escaped \"tomorrow\" !high""#)
    }

    func testQuotedApostrophesAndUnicodeOffsets() {
        for title in ["read 'don't schedule tomorrow'", "👨‍👩‍👧‍👦 ‘café at 6pm’", "read \"日本語 tomorrow\""] {
            assertLiteral(title)
            let parsed = capture.parse(title + " tomorrow !high")
            XCTAssertEqual(parsed.title, title)
            XCTAssertEqual(parsed.day?.raw, "2026-11-10")
            XCTAssertEqual(parsed.priority, .high)
            XCTAssertNil(parsed.remindAt)
        }
        XCTAssertEqual(capture.parse("don't forget tomorrow").title, "don't forget")
        assertLiteral("3:16")
        for title in ["everyday tasks", "everyMonday", "every!day"] { assertLiteral(title) }
    }

    func testLiteralModeAndMultilineCapture() throws {
        var engine = PlannerEngine(planner: Planner(), now: { Fixture.now }, calendar: Fixture.calendar)
        let text = "iPhone repair tomorrow !high\nweekly report"
        let literal = try engine.addTasks([text], literal: true)
        XCTAssertEqual(literal.map(\.title), [text])
        XCTAssertNil(literal[0].remindAt)
        XCTAssertEqual(literal[0].priority, .none)
        let parsed = try engine.addTasks([literalTitles.joined(separator: "\n")])
        XCTAssertEqual(parsed.map(\.title), literalTitles)
        XCTAssertTrue(parsed.allSatisfy { $0.day == "2026-11-09" && $0.repeatRule == nil && $0.priority == .none })
        XCTAssertEqual(
            TaskCapture.splitLines("- iPhone repair\n2) weekly report\n\n* monthly totals"),
            ["iPhone repair", "weekly report", "monthly totals"])
    }

    func testResetHourAndLocaleKeepExplicitSchedulingStable() {
        for locale in ["en_US_POSIX", "en_GB", "tr_TR", "fr_FR"] {
            var calendar = Fixture.calendar
            calendar.locale = Locale(identifier: locale)
            let capture = TaskCapture(now: Fixture.date("2026-11-10 02:00"), resetHour: 4, calendar: calendar)
            let c = capture.parse("iPhone repair tomorrow at 3am")
            XCTAssertEqual(c.title, "iPhone repair")
            XCTAssertEqual(c.day?.raw, "2026-11-10")
            XCTAssertEqual(Fixture.hm(c.remindAt), "2026-11-11 03:00")
            XCTAssertEqual(capture.parse("iPhone screen repair").title, "iPhone screen repair")
        }
    }

    func testEmptyAndMetadataOnlyInputNeverInventsATitle() {
        for input in ["", " ", "\n\t"] { XCTAssertEqual(capture.parse(input).title, "") }
        for input in ["!high", "#devices", "tomorrow", "every Monday", "at 17:30"] {
            XCTAssertEqual(capture.parse(input).title, input)
        }
    }

    func testMCPRoundtripPersistsLiteralAndParsedTitles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = PlannerFile(url: dir.appendingPathComponent("planner.json"))
        let server = MCPServer(
            tools: AgentTools(file: file, now: { Fixture.now }, calendar: Fixture.calendar), version: "capture-test")
        func call(_ name: String, _ args: JSON) throws -> JSON {
            let request: JSON = [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": .string(name), "arguments": args],
            ]
            let wire = try JSON.parse(request.data())
            let reply = try XCTUnwrap(server.handle(wire))
            XCTAssertNotEqual(reply["result"]?["isError"]?.bool, true)
            return reply
        }
        _ = try call("add_tasks", ["titles": .array(literalTitles.map(JSON.string))])
        XCTAssertEqual(try file.load().tasks.map(\.title), literalTitles)
        let quoted = #"read "John 3:16 tomorrow""#
        _ = try call("add_tasks", ["titles": [.string(quoted + " tomorrow !high")]])
        _ = try call("add_tasks", ["titles": ["iPhone tomorrow !high\nweekly report"], "literal": true])
        let tasks = try file.load().tasks
        XCTAssertEqual(tasks[tasks.count - 2].title, quoted)
        XCTAssertEqual(tasks[tasks.count - 2].priority, .high)
        XCTAssertEqual(tasks.last?.title, "iPhone tomorrow !high\nweekly report")
        XCTAssertEqual(tasks.last?.priority, TaskPriority.none)
        let listed = try call("list_tasks", [:])
        let content = try XCTUnwrap(listed["result"]?["content"]?.array?.first?["text"]?.string)
        for title in literalTitles { XCTAssertTrue(content.contains(title)) }
    }
}
