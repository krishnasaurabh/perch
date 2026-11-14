#if DEBUG || PERCH_TESTING
    import Foundation
    import XCTest
    @testable import PlannerCore

    final class PreviewPreferencesRoundTripTests: XCTestCase {
        func testClosedIdlePreviewCanChangeOnlyDevicePreferences() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = PlannerFile(
                url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
            let pipeline = PlannerCommandPipeline(
                file: file, clock: ClosurePlannerClock { PlannerPreviewScenarios.referenceDate })
            let initial = try PlannerPreviewScenarios.install("empty", in: file).planner
            let revision = PlannerFileRevision(url: file.url)
            let fixture = try PlannerPreviewScenarios.install("notch-idle", in: file)
            XCTAssertNotEqual(initial.preferences, fixture.planner.preferences)
            XCTAssertEqual(PlannerFileRevision(url: file.url), revision)
            XCTAssertEqual(try pipeline.perform(origin: .background) { _ in () }.state, fixture.planner)
            XCTAssertFalse(pipeline.canUndo)
            XCTAssertEqual(PlannerFileRevision(url: file.url), revision)
        }

        func testPreviewReplacementRoundTripsWithFileScopedDevicePreferences() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = PlannerFile(url: directory.appendingPathComponent("planner.json"))
            let pipeline = PlannerCommandPipeline(
                file: file, clock: ClosurePlannerClock { PlannerPreviewScenarios.referenceDate })
            _ = try pipeline.perform(origin: .background) { try $0.execute(.lifecycle(.launch)) }
            for name in ["empty", "three", "timer", "notch-idle", "notch-running", "notch-paused", "notch-reminder"] {
                let fixture = try PlannerPreviewScenarios.install(name, in: file)
                XCTAssertEqual(try file.load(), fixture.planner, name)
            }
        }
    }
#endif
