import Foundation
import PerchUI
import XCTest

final class ClipAndShortcutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testShortcutValidationAndDisplay() {
        XCTAssertEqual(ShortcutKey.default.display, "⌥N")
        XCTAssertEqual(ShortcutKey(keyCode: 0, modifiers: [.command, .control, .option, .shift]).display, "⌃⌥⇧⌘A")
        XCTAssertFalse(ShortcutKey(keyCode: 53, modifiers: [.command]).isValid)
        XCTAssertFalse(ShortcutKey(keyCode: 0, modifiers: []).isValid)
        XCTAssertEqual(ShortcutKey.validated(ShortcutKey(keyCode: 999, modifiers: [.command])), .default)
    }

    func testShortcutRoundTripAndUnknownModifierBits() throws {
        let key = ShortcutKey(keyCode: 45, modifiers: [.shift, .option])
        XCTAssertEqual(try JSONDecoder().decode(ShortcutKey.self, from: JSONEncoder().encode(key)), key)
        let flags = try JSONDecoder().decode(ShortcutModifiers.self, from: Data("1048591".utf8))
        XCTAssertEqual(flags, .all)
        XCTAssertEqual(ShortcutModifiers(flagBits: (1 << 20) | (1 << 16) | (1 << 23)), .command)
    }

    func testScreenshotFolderResolvesSharedDedicatedAndFallback() {
        let home = URL(fileURLWithPath: "/example/home", isDirectory: true)
        let dedicated = ScreenshotFolder.resolve(location: "~/captures", home: home, exists: { _ in true })
        XCTAssertEqual(dedicated.url.path, "/example/home/captures")
        XCTAssertTrue(dedicated.dedicated)
        XCTAssertFalse(ScreenshotFolder.resolve(location: "~/Downloads", home: home, exists: { _ in true }).dedicated)
        XCTAssertEqual(
            ScreenshotFolder.resolve(location: "relative", home: home, exists: { _ in true }).url.lastPathComponent,
            "Desktop")
        XCTAssertEqual(
            ScreenshotFolder.resolve(location: "/missing", home: home, exists: { _ in false }).url.lastPathComponent,
            "Desktop")
    }

    func testFolderScanHonorsBaselineHiddenTimeTagAndOrdering() {
        var scan = FolderScan(since: now, existing: ["old.png"])
        func entry(_ name: String, _ offset: Double = 0, hidden: Bool = false, tagged: Bool = false) -> FolderScan.Entry
        {
            .init(name: name, created: now.addingTimeInterval(offset), hidden: hidden, captureFlag: tagged)
        }
        let entries = [
            entry("old.png"), entry(".hidden.png", tagged: true), entry("secret.png", hidden: true),
            entry("past.png", -1, tagged: true), entry("b.PNG", 1), entry("a.mov"), entry("other.txt"),
            entry("tagged.bin", tagged: true),
        ]
        XCTAssertEqual(scan.newCaptures(entries, dedicatedFolder: false), ["tagged.bin"])
        XCTAssertEqual(scan.newCaptures(entries, dedicatedFolder: true), ["a.mov", "b.PNG"])
        XCTAssertTrue(scan.newCaptures(entries, dedicatedFolder: true).isEmpty)
        XCTAssertTrue(scan.newCaptures([], dedicatedFolder: true).isEmpty)
        XCTAssertEqual(scan.newCaptures([entry("a.mov")], dedicatedFolder: true), ["a.mov"])
    }

    private struct Item: Identifiable, Equatable { let id: Int }

    func testLetGoRestoresAnchorsAndFinalizesPreviousBatch() throws {
        var line = [1, 2, 3, 4].map(Item.init)
        var ledger = LetGoLedger<Item>()
        let first = ledger.letGo([2, 3], from: &line, now: now)
        XCTAssertEqual(line.map(\.id), [1, 4])
        XCTAssertEqual(ledger.pending?.deadline, now.addingTimeInterval(5))
        XCTAssertTrue(ledger.contains(2))
        XCTAssertTrue(ledger.undo(into: &line))
        XCTAssertEqual(line.map(\.id), [1, 2, 3, 4])
        XCTAssertTrue(ledger.expire(token: try XCTUnwrap(first.token)).isEmpty)
        let second = ledger.letGo([2], from: &line, now: now)
        let third = ledger.letGo([4], from: &line, now: now)
        XCTAssertEqual(third.finalized.map(\.id), [2])
        XCTAssertTrue(ledger.expire(token: try XCTUnwrap(second.token)).isEmpty)
        XCTAssertEqual(ledger.expire(token: try XCTUnwrap(third.token)).map(\.id), [4])
        XCTAssertFalse(ledger.undo(into: &line))
    }

    func testLetGoNoMatchDoesNotConsumePendingBatch() {
        var line = [1, 2].map(Item.init)
        var ledger = LetGoLedger<Item>()
        let token = ledger.letGo([1], from: &line, now: now).token
        XCTAssertNil(ledger.letGo([999], from: &line, now: now).token)
        XCTAssertEqual(ledger.pending?.token, token)
        XCTAssertTrue(ledger.undo(into: &line))
        XCTAssertEqual(line.map(\.id), [1, 2])
    }

    func testVaultCopiesWithUniqueNamesAndInjectedTimestamp() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("sample.txt")
        try Data("fixture".utf8).write(to: source)
        let vault = root.appendingPathComponent("vault")
        let one = try ClipVault.keepCopy(of: source, in: vault, now: now)
        let two = try ClipVault.keepCopy(of: source, in: vault, now: now)
        XCTAssertEqual(one.lastPathComponent, "sample.txt")
        XCTAssertEqual(two.lastPathComponent, "sample 2.txt")
        XCTAssertEqual(try Data(contentsOf: one), Data("fixture".utf8))
        XCTAssertEqual(try one.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, now)
        XCTAssertTrue(ClipVault.owns(one, vault: vault))
        XCTAssertFalse(ClipVault.owns(source, vault: vault))
        XCTAssertFalse(ClipVault.owns(vault, vault: vault))
        // Directory enumeration may canonicalize /var on macOS; compare the actual listed URL,
        // not a lexical alias returned by copyItem. Both still identify the same retained copy.
        let listedCopy = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: vault, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent == two.lastPathComponent })
        XCTAssertEqual(ClipVault.sweep(vault, olderThan: now.addingTimeInterval(1), keeping: [one.path]), [listedCopy])
        XCTAssertFalse(FileManager.default.fileExists(atPath: two.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: one.path))
    }

    func testVaultTemporaryAndComponentBoundaries() {
        XCTAssertTrue(ClipVault.isTemporary(URL(fileURLWithPath: "/example/tmp/a"), tempDirectory: "/example/tmp"))
        XCTAssertFalse(
            ClipVault.isTemporary(URL(fileURLWithPath: "/example/tmp-other/a"), tempDirectory: "/example/tmp"))
        XCTAssertTrue(ClipVault.isTemporary(URL(fileURLWithPath: "/example/TemporaryItems/a")))
        XCTAssertFalse(ClipVault.isInside("/a/file", "/"))
    }
}
