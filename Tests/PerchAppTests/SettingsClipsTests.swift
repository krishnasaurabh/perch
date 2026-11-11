import AppKit
import EventKit
import PerchUI
import PlannerCore
import XCTest
@testable import PerchApp

@MainActor
private final class PanelPermissionFake: PermissionAccess {
    var state = PermissionReading(.notDetermined)
    var requests = 0
    func read(_ feature: PermissionFeature) async -> PermissionReading { state }
    func request(_ feature: PermissionFeature) async throws {
        requests += 1
        state = PermissionReading(.denied)
    }
}

@MainActor
private final class ClipsPasteboardFake: PasteboardAccess {
    var changeCount = 0
    var declaredTypes: [String] = []
    var fileURLs: [URL] = []
    var imageData: Data?
    var plainText: String?
    func replace(with value: PasteboardValue) {
        changeCount += 1
        fileURLs = []; imageData = nil; plainText = nil
        switch value {
        case .file(let url): fileURLs = [url]
        case .text(let text): plainText = text
        case .image(let data): imageData = data
        }
    }
}

final class SettingsClipsTests: XCTestCase {
    @MainActor func testPermissionPanelPublishesQueriedDenialRatherThanSuccess() async {
        let fake = PanelPermissionFake()
        let model = PermissionPanelModel(access: fake)
        await model.refresh()
        XCTAssertEqual(model.readings[.calendar]?.state, .notDetermined)
        await model.request(.calendar)
        XCTAssertEqual(fake.requests, 1)
        XCTAssertEqual(model.readings[.calendar]?.state, .denied)
        XCTAssertNil(model.requesting)
        fake.state = PermissionReading(.allowed)
        await model.refresh()
        XCTAssertEqual(model.readings[.calendar]?.state, .allowed)
        fake.state = PermissionReading(.denied)
        await model.refresh()
        XCTAssertEqual(model.readings[.calendar]?.state, .revoked)
        XCTAssertEqual(fake.requests, 1)
    }

    @MainActor func testEventKitStatesDoNotTreatWriteOnlyAsReadAccess() async {
        XCTAssertEqual(SettingsPermissionAccess.eventState(.notDetermined).state, .notDetermined)
        XCTAssertEqual(SettingsPermissionAccess.eventState(.fullAccess).state, .allowed)
        XCTAssertEqual(SettingsPermissionAccess.eventState(.writeOnly).state, .limited)
        XCTAssertEqual(SettingsPermissionAccess.eventState(.denied).state, .denied)
        XCTAssertEqual(SettingsPermissionAccess.eventState(.restricted).state, .restricted)
    }

    @MainActor func testClipsCopyTypesPinSweepAndUndoWithIsolatedStorage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        let store = PlannerStore(file: file, watching: false)
        let pasteboard = ClipsPasteboardFake()
        let clips = ClipsService(store: store, pasteboard: pasteboard, monitoring: false)
        let textURL = root.appendingPathComponent("Notes.txt")
        try Data("Synthetic notes for the garden".utf8).write(to: textURL)
        clips.add(.text("Synthetic copied text"), source: "dropped")
        let text = try XCTUnwrap(clips.clips.first)
        clips.add(.image(Data([1, 2, 3])), source: "dropped")
        let image = try XCTUnwrap(clips.clips.first)
        clips.add(.file(textURL), source: "dropped")
        let document = try XCTUnwrap(clips.clips.first)
        clips.copy(text)
        XCTAssertEqual(pasteboard.plainText, "Synthetic copied text")
        clips.copy(image)
        XCTAssertEqual(pasteboard.imageData, Data([1, 2, 3]))
        clips.copy(document)
        XCTAssertEqual(pasteboard.fileURLs, [try XCTUnwrap(clips.clipURL(document))])
        XCTAssertEqual(ClipPreview.readText(at: pasteboard.fileURLs[0]), "Synthetic notes for the garden")
        clips.togglePin(text.id)
        let originalIDs = clips.clips.map(\.id)
        clips.sweep()
        XCTAssertEqual(clips.clips.map(\.id), [text.id])
        XCTAssertEqual(clips.letGoBanner?.count, 2)
        clips.undoLetGo()
        XCTAssertEqual(clips.clips.map(\.id), originalIDs)
        XCTAssertTrue(try XCTUnwrap(clips.clips.first { $0.id == text.id }).pinned)
        XCTAssertNil(clips.letGoBanner)
        clips.letGo(text.id)
        XCTAssertFalse(clips.clips.contains { $0.id == text.id })
        clips.undoLetGo()
        XCTAssertEqual(clips.clips.map(\.id), originalIDs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: textURL.path))
    }
}
