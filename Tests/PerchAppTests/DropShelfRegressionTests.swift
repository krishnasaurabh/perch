import AppKit
import Combine
import Foundation
import PerchUI
import PlannerCore
import XCTest
@testable import PerchApp

final class DropShelfRegressionTests: XCTestCase {
    @MainActor
    func testTopEdgeApproachReleaseAndStripHitTesting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(
            file: PlannerFile(
                url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences()),
            watching: false)
        let model = NotchModel()
        let strips = NotchStrips(store: store, model: model)
        model.strips = strips
        let geometry = NotchGeometry(
            screen: .init(
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 866), safeAreaTop: 34,
                auxiliaryLeftWidth: 620, auxiliaryRightWidth: 620, isBuiltIn: true))
        let screen = NotchScreenState(id: 1, geometry: geometry)
        model.screenID = screen.id; model.geometry = geometry
        var dragging = false
        let shelf = ClipsService(store: store, monitoring: false, dragEligibility: { dragging })
        let top = CGPoint(x: geometry.notchRect.midX, y: geometry.notchRect.maxY)
        XCTAssertTrue(shelf.routeShelfDrag(at: top, model: model, screens: [screen.id: screen]))
        XCTAssertFalse(shelf.shelfVisible, "Hover alone cannot show the shelf")
        dragging = true
        XCTAssertTrue(shelf.routeShelfDrag(at: top, model: model, screens: [screen.id: screen]))
        XCTAssertTrue(shelf.shelfVisible, "Dragging at the screen's exact top edge opens the shelf")
        XCTAssertEqual(strips.currentActivity?.stripKind, .dropShelf)
        strips.setBounds(CGSize(width: 640, height: 180), geometry: geometry)
        let stripTop = CGPoint(x: strips.bounds.minX + 1, y: strips.bounds.maxY)
        XCTAssertEqual(strips.contains(top, on: screen.id), true)
        XCTAssertEqual(strips.contains(stripTop, on: screen.id), true)
        XCTAssertEqual(strips.contains(CGPoint(x: strips.bounds.midX, y: strips.bounds.midY), on: screen.id), true)
        XCTAssertEqual(strips.contains(top, on: 2), nil, "Only the active screen routes strip input")
        let outside = CGPoint(x: strips.bounds.maxX + 1, y: strips.bounds.midY)
        XCTAssertEqual(strips.contains(outside, on: screen.id), false)
        dragging = false
        shelf.trackShelfPointer(at: stripTop, model: model)
        XCTAssertTrue(shelf.shelfVisible, "Releasing over the top edge does not count as leaving")
        shelf.trackShelfPointer(at: outside, model: model)
        XCTAssertFalse(shelf.shelfVisible)
        XCTAssertNil(strips.currentActivity)
        dragging = true
        let interior = CGPoint(x: geometry.notchRect.midX, y: geometry.notchRect.midY)
        XCTAssertTrue(shelf.routeShelfDrag(at: interior, model: model, screens: [screen.id: screen]))
        XCTAssertTrue(shelf.shelfVisible, "Interior approach remains supported")
    }

    @MainActor
    func testIncomingProviderIdentitySurvivesRestartAndDragOut() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(
            file: PlannerFile(
                url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences()),
            watching: false)
        let shelf = ClipsService(store: store, monitoring: false)
        let texts = [
            "Note: buy milk", "TODO: fix login", "https://example.com/still-plain-text", "Ordinary text",
            "  Keep café 🪶\nsecond line\t ",
        ]
        let links = [URL(string: "https://example.com/design-board")!, URL(string: "mailto:hello@example.com")!]
        let providers =
            texts.map { NSItemProvider(object: $0 as NSString) }
            + links.map { NSItemProvider(object: $0 as NSURL) }
        for (index, provider) in providers.enumerated() {
            let arrived = expectation(description: "Explicit drop loads into the shelf")
            let subscription = shelf.$clips.filter { $0.count == index + 1 }.prefix(1).sink { _ in arrived.fulfill() }
            XCTAssertTrue(shelf.acceptDrop([provider]))
            await fulfillment(of: [arrived], timeout: 2)
            withExtendedLifetime(subscription) {}
            let expected: ClipsService.Clip.Content =
                index < texts.count ? .text(texts[index]) : .link(links[index - texts.count])
            XCTAssertEqual(
                shelf.clips.first?.content, expected,
                "Input \(index), types \(provider.registeredTypeIdentifiers), route \(String(describing: ClipsService.DropRepresentation(identifiers: provider.registeredTypeIdentifiers)))"
            )
        }
        let restarted = ClipsService(store: store, monitoring: false)
        XCTAssertEqual(restarted.clips.map(\.id), shelf.clips.map(\.id))
        XCTAssertEqual(restarted.clips.map(\.content), shelf.clips.map(\.content))
        for text in texts {
            let clip = try XCTUnwrap(restarted.clips.first { $0.content == .text(text) })
            let provider = restarted.dragProvider(for: clip)
            XCTAssertFalse(provider.hasItemConformingToTypeIdentifier("public.url"), "Text is not a typed URL")
            let exported: String? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: String.self) { value, _ in continuation.resume(returning: value) }
            }
            XCTAssertEqual(exported, text, "Punctuation, spacing and URL-shaped text remain unchanged")
        }
        for link in links {
            let clip = try XCTUnwrap(restarted.clips.first { $0.content == .link(link) })
            let provider = restarted.dragProvider(for: clip)
            XCTAssertTrue(provider.hasItemConformingToTypeIdentifier("public.url"))
            let exported: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { value, _ in continuation.resume(returning: value) }
            }
            XCTAssertEqual(exported, link, "An explicitly supplied URL stays a URL across persistence")
        }
    }
}
