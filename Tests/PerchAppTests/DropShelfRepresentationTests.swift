import AppKit
import Combine
import Foundation
import PlannerCore
import UniformTypeIdentifiers
import XCTest
@testable import PerchApp

final class DropShelfRepresentationTests: XCTestCase {
    @MainActor
    func testRegisteredRepresentationsUseSourceFidelityRatherThanConvertibleObjects() {
        typealias Representation = ClipsService.DropRepresentation
        XCTAssertEqual(
            Representation(identifiers: ["public.utf8-plain-text", "public.url"]), .text("public.utf8-plain-text"))
        XCTAssertEqual(
            Representation(identifiers: ["public.url", "public.utf8-plain-text"]), .link("public.url"))
        XCTAssertEqual(
            Representation(identifiers: ["public.file-url", "public.url"]), .file("public.file-url"))
        XCTAssertEqual(
            Representation(identifiers: ["public.png", "public.utf8-plain-text"]), .image("public.png"))
        XCTAssertNil(Representation(identifiers: ["public.data"]))
    }

    @MainActor
    func testRawUTF8AndUTF16ProvidersPreserveExactTextAndNeverExportURLTypes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(
            file: PlannerFile(
                url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences()),
            watching: false)
        let shelf = ClipsService(store: store, monitoring: false)
        let cases: [(String, String, String.Encoding)] = [
            ("Note: buy milk", UTType.utf8PlainText.identifier, .utf8),
            ("https://example.com/only-text", UTType.utf8PlainText.identifier, .utf8),
            ("  café 🪶\nsecond line\t ", UTType.utf16ExternalPlainText.identifier, .utf16),
        ]
        for (index, input) in cases.enumerated() {
            let (text, type, encoding) = input
            let provider = NSItemProvider()
            let data = try XCTUnwrap(text.data(using: encoding))
            provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
                completion(data, nil); return nil
            }
            let arrived = expectation(description: "Exact raw text arrives")
            let subscription = shelf.$clips.filter { $0.count == index + 1 }.prefix(1).sink { _ in arrived.fulfill() }
            XCTAssertTrue(shelf.acceptDrop([provider]))
            await fulfillment(of: [arrived], timeout: 2)
            withExtendedLifetime(subscription) {}
            XCTAssertEqual(shelf.clips.first?.content, .text(text))
        }
        let restarted = ClipsService(store: store, monitoring: false)
        for (text, _, _) in cases {
            let clip = try XCTUnwrap(restarted.clips.first { $0.content == .text(text) })
            let provider = restarted.dragProvider(for: clip)
            XCTAssertEqual(provider.registeredTypeIdentifiers, [UTType.utf8PlainText.identifier])
            let exported: Data? = await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            XCTAssertEqual(exported, Data(text.utf8))
        }
    }
}
