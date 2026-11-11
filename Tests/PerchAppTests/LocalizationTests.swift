import Foundation
import XCTest
@testable import PerchApp
@testable import PlannerCore

final class LocalizationTests: XCTestCase {
    func testAppErrorsMapThroughCatalogAndKeepDynamicDetails() {
        let pseudo = Locale(identifier: "zz")
        XCTAssertEqual(
            AppL10n.format("AI sorting failed: %@", locale: pseudo, "Unavailable"),
            "⟦ÅÎ sörtïng fàïlëd: Unavailable ·~⟧")
        XCTAssertEqual(AppL10n.text("Could not delete this task.", locale: pseudo), "⟦Cöüld nöt dëlëtë thïs tàsk. ·~⟧")
        let error = PerchAppError.unsupportedParserLanguage("fr")
        XCTAssertTrue(error.message.contains("nothing was added"))
        XCTAssertTrue(error.message.contains("fr"))
    }

    @MainActor
    func testUnsupportedParserLanguageDoesNotWriteOrRewriteTasks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("planner.json")
        let store = PlannerStore(
            file: PlannerFile(url: url), now: { Date(timeIntervalSince1970: 1_800_000_000) },
            watching: false, parserLanguage: { nil })
        XCTAssertNil(store.addTasks(["Repair tomorrow at 5pm"]))
        guard case .unsupportedParserLanguage = store.lastError else {
            return XCTFail("unsupported language error missing")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(store.planner.tasks.isEmpty)

        // Literal imports never invoke the natural-language parser and remain available.
        let added = try XCTUnwrap(store.addTasks(["Repair tomorrow at 5pm"], literal: true))
        XCTAssertEqual(added.first?.title, "Repair tomorrow at 5pm")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try PlannerFile(url: url).load().tasks.first?.title, "Repair tomorrow at 5pm")
    }
}
