import Foundation
import PlannerCore
import XCTest
@testable import PerchUI
@testable import PerchApp

private final class ConsentPasteboardFake: PasteboardAccess {
    var changeCount = 0
    var declaredTypes: [String] = []
    var fileURLs: [URL] = []
    var imageData: Data?
    var plainText: String?
    func replace(with value: PasteboardValue) {}
}

private final class ScreenshotAccessCounts: @unchecked Sendable {
    struct Snapshot {
        let queries: Int
        let opens: Int
        let enumerations: Int
    }

    private let lock = NSLock()
    private var queries = 0
    private var opens = 0
    private var enumerations = 0

    func queryStarted() {
        lock.lock()
        queries += 1
        lock.unlock()
    }

    func folderOpened() {
        lock.lock()
        opens += 1
        lock.unlock()
    }

    func folderEnumerated() {
        lock.lock()
        enumerations += 1
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(queries: queries, opens: opens, enumerations: enumerations)
    }
}

private final class SyntheticScreenshotQuery: NSObject, ScreenshotQuerying {
    var predicate: NSPredicate?
    var searchScopes: [Any] = []
    private let counts: ScreenshotAccessCounts

    init(counts: ScreenshotAccessCounts) {
        self.counts = counts
    }

    func start() -> Bool {
        counts.queryStarted()
        return true
    }

    func stop() {}
}

private struct SyntheticFolderWatcher: FolderWatching {
    let counts: ScreenshotAccessCounts

    func start() -> Bool {
        counts.folderOpened()
        return true
    }

    func stop() {}
}

final class ClipsConsentTests: XCTestCase {
    @MainActor func testFreshStartupDoesNotOpenOrEnumerateScreenshotFolderBeforeWelcomeConsent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        let store = PlannerStore(file: file, watching: false)
        let counts = ScreenshotAccessCounts()
        let queue = DispatchQueue(label: "ClipsConsentTests.fresh")
        let clips = ClipsService(
            store: store,
            pasteboard: ConsentPasteboardFake(),
            queryFactory: { SyntheticScreenshotQuery(counts: counts) },
            watcherFactory: { _, _, _ in SyntheticFolderWatcher(counts: counts) },
            folderEntries: { _ in
                counts.folderEnumerated()
                return []
            },
            folderProvider: { ScreenshotFolder.Resolved(url: root, dedicated: true) },
            folderQueue: queue)
        queue.sync {}
        let access = counts.snapshot()
        XCTAssertEqual(access.opens, 0, "A fresh profile opened the screenshot folder before Welcome consent")
        XCTAssertEqual(access.enumerations, 0, "A fresh profile enumerated screenshots before Welcome consent")
        XCTAssertEqual(
            access.queries, 0, "A fresh profile started screenshot metadata monitoring before Welcome consent")
        let delegate = AppDelegate()
        delegate.store = store
        delegate.completeWelcome()
        queue.sync {}
        let afterWelcome = counts.snapshot()
        XCTAssertTrue(store.prefs.welcomeCompleted)
        XCTAssertFalse(store.prefs.catchScreenshots)
        XCTAssertEqual(afterWelcome.opens, 0)
        XCTAssertEqual(afterWelcome.enumerations, 0)
        XCTAssertEqual(afterWelcome.queries, 0)

        WelcomeScreenshotConsent(store: store).isEnabled.wrappedValue = true
        queue.sync {}
        let consented = counts.snapshot()
        XCTAssertTrue(store.prefs.catchScreenshots)
        XCTAssertEqual(consented.opens, 1)
        XCTAssertEqual(consented.enumerations, 1)
        XCTAssertEqual(consented.queries, 1)
        withExtendedLifetime(clips) {}
    }

    @MainActor func testSavedScreenshotOptInStartsWithoutANewConsentPrompt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("planner.json")
        try Data(
            #"{"version":1,"preferences":{"catchScreenshots":true,"welcomeCompleted":false}}"#.utf8
        ).write(to: url)
        let store = PlannerStore(
            file: PlannerFile(url: url, preferences: MemoryPlannerPreferences()), watching: false)
        let counts = ScreenshotAccessCounts()
        let queue = DispatchQueue(label: "ClipsConsentTests.upgrade")
        let clips = ClipsService(
            store: store,
            pasteboard: ConsentPasteboardFake(),
            queryFactory: { SyntheticScreenshotQuery(counts: counts) },
            watcherFactory: { _, _, _ in SyntheticFolderWatcher(counts: counts) },
            folderEntries: { _ in
                counts.folderEnumerated()
                return []
            },
            folderProvider: { ScreenshotFolder.Resolved(url: root, dedicated: true) },
            folderQueue: queue)
        queue.sync {}
        let access = counts.snapshot()
        XCTAssertTrue(store.prefs.catchScreenshots)
        XCTAssertFalse(store.prefs.welcomeCompleted)
        XCTAssertEqual(access.opens, 1)
        XCTAssertEqual(access.enumerations, 1)
        XCTAssertEqual(access.queries, 1)
        withExtendedLifetime(clips) {}
    }
}
