#if DEBUG || PERCH_TESTING
    import Foundation
    import XCTest

    @testable import PlannerCore

    final class PlannerPreviewScenariosTests: XCTestCase {
        func testRunningDayAndExactClock() throws {
            let fixture = try PlannerPreviewScenarios.make("today-running")
            let today = fixture.planner.tasks.filter { $0.day == fixture.day }
            XCTAssertEqual(today.count, 6)
            XCTAssertEqual(today.filter(\.done).count, 1)
            let current = try XCTUnwrap(today.first { $0.title == "Draft the test checklist" })
            XCTAssertEqual(current.steps.count, 4)
            XCTAssertEqual(current.steps.filter(\.done).count, 2)
            XCTAssertEqual(fixture.planner.focus?.taskID, current.id)
            XCTAssertEqual(fixture.planner.focus?.remaining(at: fixture.now), 1450)
        }

        func testBeforeStartAndEditingHaveNoRunningBlock() throws {
            for name in ["today-before", "today-editing"] {
                let fixture = try PlannerPreviewScenarios.make(name)
                XCTAssertNil(fixture.planner.focus)
                XCTAssertEqual(fixture.planner.tasks.count, 6)
                XCTAssertEqual(fixture.planner.tasks.filter(\.done).count, 0)
                XCTAssertEqual(fixture.planner.tasks.first?.carriedFrom, fixture.day.adding(days: -1))
            }
            XCTAssertEqual(
                try PlannerPreviewScenarios.make("today-before").captureText,
                "Prep for the design review at 1:30 for 20 min")
            XCTAssertNotNil(try PlannerPreviewScenarios.make("today-editing").editingTaskID)
        }

        func testEmptyAndFullCalendarWeek() throws {
            XCTAssertTrue(try PlannerPreviewScenarios.make("today-empty").planner.tasks.isEmpty)
            let fixture = try PlannerPreviewScenarios.make("week-full")
            let start = fixture.day.adding(days: -4)
            let counts = (0..<7).map { offset in
                fixture.planner.tasks.filter { $0.day == start.adding(days: offset) }.count
            }
            XCTAssertEqual(counts, [4, 3, 4, 3, 6, 2, 0])
            XCTAssertEqual(fixture.planner.tasks.filter(\.done).count, 15)
        }

        func testNotchAndWindowSamplesUseExistingFields() throws {
            for name in ["strip-heads-up", "strip-ended"] {
                let fixture = try PlannerPreviewScenarios.make(name)
                let task = try XCTUnwrap(fixture.planner.tasks.first { $0.id == fixture.planner.focus?.taskID })
                XCTAssertEqual(task.steps.filter(\.done).count, 3)
            }
            let agent = try PlannerPreviewScenarios.make("strip-agent")
            XCTAssertEqual(agent.planner.tasks.filter { $0.agentID != nil }.count, 2)
            XCTAssertEqual(try PlannerPreviewScenarios.make("notch-paused").planner.focus?.state, .paused)
            let review = try PlannerPreviewScenarios.make("window-review")
            XCTAssertEqual(review.planner.focusSegments.reduce(0) { $0 + $1.seconds }, 7800)
            let projects = try PlannerPreviewScenarios.make("window-projects").planner
            XCTAssertEqual(projects.projects.map(\.name), ["Work", "Launch", "Home", "Money"])
            XCTAssertEqual(projects.tasks.filter { $0.projectID == nil }.count, 4)
        }

        func testEveryScenarioIsRepeatableAndRoundTrips() throws {
            for name in PlannerPreviewScenarios.names {
                let a = try PlannerPreviewScenarios.make(name)
                let b = try PlannerPreviewScenarios.make(name)
                XCTAssertEqual(a.planner, b.planner, name)
                let data = try PlannerFile.encoder.encode(a.planner)
                XCTAssertEqual(try PlannerFile.decoder.decode(Planner.self, from: data), a.planner, name)
            }
            XCTAssertThrowsError(try PlannerPreviewScenarios.make("unknown"))
        }

        func testFileBackedFixturesPreserveEveryField() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = PlannerFile(
                url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
            for name in AppLaunchConfiguration.previewScenarioNames.sorted() {
                let fixture = try PlannerPreviewScenarios.install(name, in: file)
                XCTAssertEqual(try file.load(), fixture.planner, name)
            }
            let before = try file.load()
            XCTAssertThrowsError(try PlannerPreviewScenarios.install("unknown", in: file))
            XCTAssertEqual(try file.load(), before)
        }

        func testLegacyCasesKeepTheirReducer() throws {
            for scenario in [PlannerPreview.empty, .three, .timer, .insights] {
                var engine = PlannerEngine(planner: Planner(), now: { PlannerPreviewScenarios.referenceDate })
                _ = try engine.execute(.seedPreview(scenario))
                if case .empty = scenario { XCTAssertTrue(engine.planner.tasks.isEmpty) }
                if case .timer = scenario { XCTAssertEqual(engine.planner.focus?.state, .running) }
            }
        }
    }
#endif
