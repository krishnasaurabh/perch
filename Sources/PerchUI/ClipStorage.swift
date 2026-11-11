import Foundation
import PlannerCore

/// Where screenshots are saved: the `com.apple.screencapture` `location` default, else the Desktop.
public enum ScreenshotFolder {
    public struct Resolved: Equatable, Sendable {
        public let url: URL
        /// A folder used only for captures, so any image or movie there counts even without the capture tag.
        public let dedicated: Bool
    }

    public static func resolve(location: String?, home: URL, exists: (String) -> Bool) -> Resolved {
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true).standardizedFileURL
        var path = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if path == "~" || path.hasPrefix("~/") { path = home.path + path.dropFirst() }
        guard path.hasPrefix("/"), exists(path) else { return Resolved(url: desktop, dedicated: false) }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let shared = [
            home, desktop, home.appendingPathComponent("Documents"), home.appendingPathComponent("Downloads"),
        ]
        .map { $0.standardizedFileURL.path }
        return Resolved(url: url, dedicated: !shared.contains(url.path))
    }
}

/// Decides which entries of a folder listing are new captures. Pure: the watcher feeds it listings.
public struct FolderScan {
    public struct Entry: Equatable, Sendable {
        public init(name: String, created: Date, hidden: Bool, captureFlag: Bool) {
            self.name = name; self.created = created; self.hidden = hidden; self.captureFlag = captureFlag
        }
        public let name: String
        public let created: Date
        public let hidden: Bool
        /// The file carries macOS's screen-capture tag (`com.apple.metadata:kMDItemIsScreenCapture`).
        public let captureFlag: Bool
    }

    public static let mediaExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "pdf", "mov", "mp4",
    ]
    public let since: Date
    /// Names present and already accounted for. Names that disappear are forgotten, so a re-created file counts again.
    public private(set) var seen: Set<String>

    public init(since: Date, existing: Set<String>) {
        self.since = since
        seen = existing
    }

    /// New capture names in this listing, oldest first.
    public mutating func newCaptures(_ entries: [Entry], dedicatedFolder: Bool) -> [String] {
        seen.formIntersection(entries.map(\.name))
        let fresh = entries.filter { e in
            guard !e.hidden, !e.name.hasPrefix("."), e.created >= since, !seen.contains(e.name) else { return false }
            if e.captureFlag { return true }
            return dedicatedFolder && Self.mediaExtensions.contains((e.name as NSString).pathExtension.lowercased())
        }
        .sorted { ($0.created, $0.name) < ($1.created, $1.name) }
        seen.formUnion(fresh.map(\.name))
        return fresh.map(\.name)
    }
}

/// Perch's own copies of clips whose source would vanish (temporary files).
public enum ClipVault {
    /// Unreferenced copies older than this are removed at launch.
    public static let retention: TimeInterval = 7 * 86_400

    public static func isTemporary(_ url: URL, tempDirectory: String = NSTemporaryDirectory()) -> Bool {
        let std = url.standardizedFileURL
        if std.pathComponents.contains("TemporaryItems") { return true }
        return ["/private/var/folders", "/var/folders", "/tmp", "/private/tmp", tempDirectory].contains {
            isInside(std.path, $0)
        }
    }

    /// Copies `source` into `vault` under a free name ("Name 2.png" on collision) and returns the copy.
    public static func keepCopy(of source: URL, in vault: URL, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: vault, withIntermediateDirectories: true)
        let ext = source.pathExtension
        let base = source.deletingPathExtension().lastPathComponent
        var target = vault.appendingPathComponent(source.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = vault.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        try fm.copyItem(at: source, to: target)
        // Retention counts from when we kept it, not from the source's date.
        try? fm.setAttributes([.modificationDate: now], ofItemAtPath: target.path)
        return target
    }

    public static func owns(_ url: URL, vault: URL) -> Bool {
        isInside(url.resolvingSymlinksInPath().path, vault.resolvingSymlinksInPath().path)
    }

    /// Deletes files in `vault` last modified before `cutoff`, except paths in `keeping`. Returns what it removed.
    @discardableResult
    public static func sweep(_ vault: URL, olderThan cutoff: Date, keeping: Set<String>) -> [URL] {
        let fm = FileManager.default
        let keep = Set(keeping.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let items = try? fm.contentsOfDirectory(at: vault, includingPropertiesForKeys: Array(keys)) else {
            return []
        }
        var removed: [URL] = []
        for u in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let v = try? u.resourceValues(forKeys: keys)
            guard v?.isRegularFile == true, let mod = v?.contentModificationDate, mod < cutoff,
                !keep.contains(u.resolvingSymlinksInPath().path)
            else { continue }
            if (try? fm.removeItem(at: u)) != nil { removed.append(u) }
        }
        return removed
    }

    /// Component-wise prefix test; a root directory never counts.
    public static func isInside(_ path: String, _ dir: String) -> Bool {
        let p = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let d = URL(fileURLWithPath: dir).standardizedFileURL.pathComponents
        return d.count > 1 && p.count > d.count && Array(p.prefix(d.count)) == d
    }
}

/// "Let go" with a short undo window. Holds the most recent batch; a new let-go makes the previous one final.
public struct LetGoLedger<Item: Identifiable> {
    public init() {}
    public static var window: TimeInterval { 5 }

    public struct Entry {
        public let item: Item
        /// Position on the line when let go, used if the anchor is gone too.
        public let index: Int
        /// The next item that stayed on the line; the item goes back right before it (nil: the end).
        public let anchor: Item.ID?
    }

    public struct Pending {
        public let token: Int
        public let deadline: Date
        public let items: [Entry]
    }

    public private(set) var pending: Pending?
    private var nextToken = 1

    /// Removes `ids` from `line`. Returns this batch's token (nil when nothing matched, leaving any pending batch alone)
    /// and the items of the previous batch, which are now final.
    public mutating func letGo(_ ids: [Item.ID], from line: inout [Item], now: Date) -> (token: Int?, finalized: [Item])
    {
        let wanted = Set(ids)
        let indices = line.indices.filter { wanted.contains(line[$0].id) }
        guard !indices.isEmpty else { return (nil, []) }
        let finalized = pending?.items.map(\.item) ?? []
        let entries = indices.map { i in
            Entry(item: line[i], index: i, anchor: line[(i + 1)...].first { !wanted.contains($0.id) }?.id)
        }
        line.removeAll { wanted.contains($0.id) }
        let token = nextToken
        nextToken += 1
        pending = Pending(token: token, deadline: now.addingTimeInterval(Self.window), items: entries)
        return (token, finalized)
    }

    /// Puts the pending batch back where it was. False when there is nothing to undo.
    public mutating func undo(into line: inout [Item]) -> Bool {
        guard let p = pending else { return false }
        pending = nil
        for e in p.items {
            if let a = e.anchor, let at = line.firstIndex(where: { $0.id == a }) {
                line.insert(e.item, at: at)
            } else if e.anchor == nil {
                line.append(e.item)
            } else {
                line.insert(e.item, at: min(e.index, line.count))
            }
        }
        return true
    }

    /// The undo window for `token` ran out. Returns the items now gone for good (empty if superseded or undone).
    public mutating func expire(token: Int) -> [Item] {
        guard let p = pending, p.token == token else { return [] }
        pending = nil
        return p.items.map(\.item)
    }

    public func contains(_ id: Item.ID) -> Bool { pending?.items.contains { $0.item.id == id } ?? false }
}
