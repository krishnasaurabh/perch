import AppKit
import Combine
import PlannerCore
import QuickLookThumbnailing
import SwiftUI

/// Clips: new screenshots and screen recordings (and optionally anything copied) hang on a line in the notch.
///
/// Screenshots arrive two ways, deduplicated by path: Spotlight (`NSMetadataQuery`, no permission needed but it can lag)
/// and a file-descriptor watch on the `com.apple.screencapture` save folder (instant once Perch can read that folder).
/// Files in a temporary location (a screenshot thumbnail dragged onto the notch) are copied into Application Support
/// first, so the clip keeps working after macOS cleans up. Letting go of clips can be undone for 5 seconds.
@MainActor
final class ClipsService: ObservableObject {
    struct Clip: Identifiable, Equatable {
        enum Content: Equatable { case file(URL), text(String), image(Data) }
        let id = UUID()
        var content: Content
        var source: String  // captured, copied, dropped
        var date: Date
        var pinned = false
        var thumbnail: NSImage?
        /// For a file copied out of a temporary location: where it came from.
        var origin: URL?
        static func == (a: Clip, b: Clip) -> Bool {
            a.id == b.id && a.pinned == b.pinned && a.thumbnail === b.thumbnail
        }

        var title: String {
            switch content {
            case .file(let u): return u.lastPathComponent
            case .text(let s): return String(s.prefix(60))
            case .image: return "Copied image"
            }
        }
    }

    /// What the undo toast shows while a let-go can still be taken back.
    struct LetGoBanner: Equatable {
        let token: Int
        let count: Int
        let deadline: Date
    }

    /// State of the screenshot-folder watch, for a status line in Clips.
    enum FolderWatch: Equatable {
        case off
        case watching(URL)
        case unreadable(URL)
    }

    static let capacity = 12
    @Published private(set) var clips: [Clip] = []
    @Published private(set) var letGoBanner: LetGoBanner?
    @Published private(set) var folderWatch: FolderWatch = .off
    let store: PlannerStore
    weak var model: NotchModel?
    /// Application Support/Perch/Clips, next to planner.json (so `PERCH_DATA` relocates it too).
    let vault = PlannerFile.defaultURL.deletingLastPathComponent().appendingPathComponent("Clips", isDirectory: true)

    private var query: NSMetadataQuery?
    private var queryObserver: NSObjectProtocol?
    private var startedAt = Date()
    private var watcher: FolderWatcher?
    private var folder: ScreenshotFolder.Resolved?
    private var scan: FolderScan?
    private var folderCheckTimer: Timer?
    private let folderQueue = DispatchQueue(label: "perch.clips.folder", qos: .utility)
    private var watchGeneration = 0
    private var watchStarting = false
    /// Every path a capture source already reported, so Spotlight catching up later never hangs a clip twice.
    private var caughtPaths = Set<String>()
    private var ledger = LetGoLedger<Clip>()
    private var pasteboardCount = NSPasteboard.general.changeCount
    private var pasteTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(store: PlannerStore) {
        self.store = store
        store.$planner.map(\.preferences.catchScreenshots).removeDuplicates().sink { [weak self] on in
            on ? self?.startScreenshots() : self?.stopScreenshots()
        }.store(in: &cancellables)
        store.$planner.map(\.preferences.catchCopies).removeDuplicates().sink { [weak self] on in
            on ? self?.startPasteboard() : self?.stopPasteboard()
        }.store(in: &cancellables)
        // The line is not persisted, so kept copies from earlier runs are orphans once they age out.
        let vault = vault
        DispatchQueue.global(qos: .utility).async {
            ClipVault.sweep(vault, olderThan: Date().addingTimeInterval(-ClipVault.retention), keeping: [])
        }
        if Self.demo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.seedDemo() }
        }
    }

    /// `--demo-clips` (screenshots, real-Mac checks): a temp file gets kept, one clip is let go, Clips opens with the toast.
    private func seedDemo() {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Perch demo clip.txt")
        try? Data("Kept out of a temporary folder.".utf8).write(to: temp)
        add(.file(temp), source: "dropped")
        add(.text("https://example.com/launch-checklist"), source: "copied")
        add(.text("Ship notes: folder watch, kept copies, undo"), source: "copied")
        if let first = clips.first { letGo(first.id) }
        debugLog("seeded kept=\(clips.compactMap(\.content.fileURL).map(\.path))")
        model?.open(page: .clips, pinned: true)
    }

    private static let demo = CommandLine.arguments.contains("--demo-clips")
    private func debugLog(_ event: String) {
        guard Self.demo else { return }
        FileHandle.standardError.write(
            Data(
                "clips: \(event) | line=\(clips.map(\.title)) pending=\(letGoBanner?.count ?? 0) watch=\(folderWatch)\n"
                    .utf8))
    }

    // MARK: Screenshots

    private func startScreenshots() {
        guard query == nil else { return }
        startedAt = Date()
        // Spotlight: no permission needed, but indexing can lag.
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(
            format: "kMDItemFSCreationDate >= %@ && (kMDItemIsScreenRecording == 1 || kMDItemIsScreenCapture == 1)",
            startedAt as NSDate)
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        queryObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate, object: q, queue: .main
        ) { [weak self] n in
            let added = (n.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem]) ?? []
            let paths = added.compactMap { $0.value(forAttribute: NSMetadataItemPathKey) as? String }
            Task { @MainActor in paths.forEach { self?.caught(URL(fileURLWithPath: $0)) } }
        }
        q.start()
        query = q
        // Folder watch: instant, and still works while Spotlight is slow or off.
        watchFolder()
        folderCheckTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recheckFolder() }
        }
    }

    private func stopScreenshots() {
        query?.stop(); query = nil
        if let o = queryObserver { NotificationCenter.default.removeObserver(o); queryObserver = nil }
        folderCheckTimer?.invalidate(); folderCheckTimer = nil
        watcher?.stop(); watcher = nil
        scan = nil; folder = nil
        watchGeneration += 1; watchStarting = false
        folderWatch = .off
    }

    /// `defaults read com.apple.screencapture location`, re-read from disk each time.
    /// `PERCH_SCREENSHOT_FOLDER` overrides it for tests, so checks never touch the user's own folders or defaults.
    private static func screencaptureLocation() -> String? {
        if let override = ProcessInfo.processInfo.environment["PERCH_SCREENSHOT_FOLDER"] { return override }
        let domain = "com.apple.screencapture" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("location" as CFString, domain) as? String
    }

    private func currentFolder() -> ScreenshotFolder.Resolved {
        ScreenshotFolder.resolve(
            location: Self.screencaptureLocation(), home: FileManager.default.homeDirectoryForCurrentUser
        ) { path in
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
        }
    }

    private func watchFolder() {
        watcher?.stop(); watcher = nil
        scan = nil
        let resolved = currentFolder()
        folder = resolved
        watchGeneration += 1
        let generation = watchGeneration
        let since = Date()
        let w = FolderWatcher(url: resolved.url, queue: folderQueue) { [weak self] reason in
            let entries = FolderWatcher.entries(in: resolved.url)
            Task { @MainActor in self?.folderChanged(entries, reason: reason, folder: resolved) }
        }
        watchStarting = true
        // Opening Desktop/Documents/Downloads can wait on the privacy prompt: never on the main thread.
        folderQueue.async { [weak self] in
            let ok = w.start()
            let existing = ok ? Set(FolderWatcher.entries(in: resolved.url).map(\.name)) : []
            Task { @MainActor in
                guard let self else { w.stop(); return }
                if self.watchGeneration == generation { self.watchStarting = false }
                guard self.watchGeneration == generation, self.query != nil else { w.stop(); return }
                guard ok else { self.folderWatch = .unreadable(resolved.url); return }
                // Baseline what was already there; only files created from `since` on are new.
                self.scan = FolderScan(since: since, existing: existing)
                self.watcher = w
                self.folderWatch = .watching(resolved.url)
            }
        }
    }

    /// The save location can change in the Screenshot app's Options menu while Perch runs.
    private func recheckFolder() {
        guard query != nil, !watchStarting else { return }
        if currentFolder() != folder || watcher == nil { watchFolder() }
    }

    private func folderChanged(
        _ entries: [FolderScan.Entry], reason: FolderWatcher.Event, folder resolved: ScreenshotFolder.Resolved
    ) {
        guard resolved == folder else { return }
        if reason == .folderMoved { watchFolder(); return }
        guard var s = scan else { return }
        let names = s.newCaptures(entries, dedicatedFolder: resolved.dedicated)
        scan = s
        names.forEach { caught(resolved.url.appendingPathComponent($0)) }
        // screencapture can tag the file a moment after it appears; look once more.
        if reason == .contents {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) { [weak self] in
                let later = FolderWatcher.entries(in: resolved.url)
                Task { @MainActor in self?.folderChanged(later, reason: .recheck, folder: resolved) }
            }
        }
    }

    /// A capture source found a new screenshot or recording.
    private func caught(_ url: URL) {
        guard caughtPaths.insert(Self.canonicalPath(url)).inserted else { return }
        add(.file(url), source: "captured")
        debugLog("caught \(url.lastPathComponent)")
    }

    // MARK: Pasteboard

    private func startPasteboard() {
        guard pasteTimer == nil else { return }
        pasteboardCount = NSPasteboard.general.changeCount
        pasteTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPasteboard() }
        }
    }

    private func stopPasteboard() { pasteTimer?.invalidate(); pasteTimer = nil }

    private func pollPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != pasteboardCount else { return }
        pasteboardCount = pb.changeCount
        // Respect password managers and transient copies (nspasteboard.org conventions).
        let skip = [
            "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        ]
        if let types = pb.types, types.contains(where: { skip.contains($0.rawValue) }) { return }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            let u = urls.first
        {
            add(.file(u), source: "copied")
        } else if let img = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            add(.image(img), source: "copied")
        } else if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(.text(s), source: "copied")
        }
    }

    // MARK: Line

    func add(_ content: Clip.Content, source: String) {
        var content = content
        var origin: URL?
        if case .file(let u) = content {
            let path = Self.canonicalPath(u)
            if clips.contains(where: { c in
                [c.origin, c.content.fileURL].contains { $0.map(Self.canonicalPath) == path }
            }) {
                return
            }
            // A temp file disappears soon: hang our own copy instead.
            if ClipVault.isTemporary(u), let kept = try? ClipVault.keepCopy(of: u, in: vault) {
                origin = u
                content = .file(kept)
            }
        } else if clips.contains(where: { $0.content == content }) {
            return
        }
        var clip = Clip(content: content, source: source, date: Date())
        clip.origin = origin
        if case .image(let d) = content { clip.thumbnail = NSImage(data: d) }
        clips.insert(clip, at: 0)
        // Oldest unpinned clips fall off the line.
        var fell: [Clip] = []
        while clips.count > Self.capacity, let i = clips.lastIndex(where: { !$0.pinned }) {
            fell.append(clips.remove(at: i))
        }
        discard(fell)
        if case .file(let u) = content { thumbnail(for: clip.id, url: u) }
        if source == "captured" {
            model?.show(
                .init(
                    kind: .clip(clipURL(clip) ?? URL(fileURLWithPath: "/")), title: "On the line", subtitle: clip.title),
                for: 3)
        }
    }

    // Retained for the baseline view compiled by the before/after CI probe.
    func remove(_ id: UUID) { letGo(id) }

    func clearUnpinned() {
        let removed = clips.filter { !$0.pinned }
        clips.removeAll { !$0.pinned }
        discard(removed)
    }

    func togglePin(_ id: UUID) { if let i = clips.firstIndex(where: { $0.id == id }) { clips[i].pinned.toggle() } }

    /// Takes clips off the line. `undoLetGo()` brings the latest batch back within `LetGoLedger.window` seconds.
    func letGo(_ ids: [UUID]) {
        let r = ledger.letGo(ids, from: &clips, now: Date())
        discard(r.finalized)
        guard let token = r.token, let p = ledger.pending else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            letGoBanner = LetGoBanner(token: token, count: p.items.count, deadline: p.deadline)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + LetGoLedger<Clip>.window) { [weak self] in
            self?.expireLetGo(token)
        }
        debugLog("let go \(p.items.count)")
    }

    func letGo(_ id: UUID) { letGo([id]) }

    /// Lets go of every unpinned clip at once, undoable as one step.
    func sweep() { letGo(clips.filter { !$0.pinned }.map(\.id)) }

    func undoLetGo() {
        guard ledger.undo(into: &clips) else { return }
        withAnimation(.easeOut(duration: 0.15)) { letGoBanner = nil }
        debugLog("undo")
    }

    private func expireLetGo(_ token: Int) {
        discard(ledger.expire(token: token))
        if letGoBanner?.token == token { withAnimation(.easeOut(duration: 0.15)) { letGoBanner = nil } }
        debugLog("undo window \(token) closed")
    }

    /// Final removal: delete our own kept copies; never touch the user's files.
    private func discard(_ gone: [Clip]) {
        let files = gone.compactMap(\.content.fileURL).filter { url in
            ClipVault.owns(url, vault: vault)
                && !clips.contains { $0.content.fileURL.map(Self.canonicalPath) == Self.canonicalPath(url) }
        }
        guard !files.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { files.forEach { try? FileManager.default.removeItem(at: $0) } }
    }

    func copy(_ clip: Clip) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch clip.content {
        case .file(let u): pb.writeObjects([u as NSURL])
        case .text(let s): pb.setString(s, forType: .string)
        case .image(let d): pb.setData(d, forType: .png)
        }
        pasteboardCount = pb.changeCount  // don't re-catch our own copy
    }

    func open(_ clip: Clip) {
        if case .file(let u) = clip.content { NSWorkspace.shared.open(u) }
    }

    func clipURL(_ clip: Clip) -> URL? { clip.content.fileURL }

    private static func canonicalPath(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    private func thumbnail(for id: UUID, url: URL) {
        let req = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 160, height: 110), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            guard let img = rep?.nsImage else { return }
            Task { @MainActor in
                if let i = self.clips.firstIndex(where: { $0.id == id }) { self.clips[i].thumbnail = img }
            }
        }
    }
}

extension ClipsService.Clip.Content {
    var fileURL: URL? { if case .file(let u) = self { return u }; return nil }
}

// BEGIN clip plumbing: Foundation only, so it can be exercised headless (extract between the markers).

/// Where screenshots are saved: the `com.apple.screencapture` `location` default, else the Desktop.
enum ScreenshotFolder {
    struct Resolved: Equatable {
        let url: URL
        /// A folder used only for captures, so any image or movie there counts even without the capture tag.
        let dedicated: Bool
    }

    static func resolve(location: String?, home: URL, exists: (String) -> Bool) -> Resolved {
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
struct FolderScan {
    struct Entry: Equatable {
        let name: String
        let created: Date
        let hidden: Bool
        /// The file carries macOS's screen-capture tag (`com.apple.metadata:kMDItemIsScreenCapture`).
        let captureFlag: Bool
    }

    static let mediaExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "pdf", "mov", "mp4"]
    let since: Date
    /// Names present and already accounted for. Names that disappear are forgotten, so a re-created file counts again.
    private(set) var seen: Set<String>

    init(since: Date, existing: Set<String>) {
        self.since = since
        seen = existing
    }

    /// New capture names in this listing, oldest first.
    mutating func newCaptures(_ entries: [Entry], dedicatedFolder: Bool) -> [String] {
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
enum ClipVault {
    /// Unreferenced copies older than this are removed at launch.
    static let retention: TimeInterval = 7 * 86_400

    static func isTemporary(_ url: URL, tempDirectory: String = NSTemporaryDirectory()) -> Bool {
        let std = url.standardizedFileURL
        if std.pathComponents.contains("TemporaryItems") { return true }
        return ["/private/var/folders", "/var/folders", "/tmp", "/private/tmp", tempDirectory].contains {
            isInside(std.path, $0)
        }
    }

    /// Copies `source` into `vault` under a free name ("Name 2.png" on collision) and returns the copy.
    static func keepCopy(of source: URL, in vault: URL) throws -> URL {
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
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
        return target
    }

    static func owns(_ url: URL, vault: URL) -> Bool {
        isInside(url.resolvingSymlinksInPath().path, vault.resolvingSymlinksInPath().path)
    }

    /// Deletes files in `vault` last modified before `cutoff`, except paths in `keeping`. Returns what it removed.
    @discardableResult
    static func sweep(_ vault: URL, olderThan cutoff: Date, keeping: Set<String>) -> [URL] {
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
    static func isInside(_ path: String, _ dir: String) -> Bool {
        let p = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let d = URL(fileURLWithPath: dir).standardizedFileURL.pathComponents
        return d.count > 1 && p.count > d.count && Array(p.prefix(d.count)) == d
    }
}

/// "Let go" with a short undo window. Holds the most recent batch; a new let-go makes the previous one final.
struct LetGoLedger<Item: Identifiable> {
    static var window: TimeInterval { 5 }

    struct Entry {
        let item: Item
        /// Position on the line when let go, used if the anchor is gone too.
        let index: Int
        /// The next item that stayed on the line; the item goes back right before it (nil: the end).
        let anchor: Item.ID?
    }

    struct Pending {
        let token: Int
        let deadline: Date
        let items: [Entry]
    }

    private(set) var pending: Pending?
    private var nextToken = 1

    /// Removes `ids` from `line`. Returns this batch's token (nil when nothing matched, leaving any pending batch alone)
    /// and the items of the previous batch, which are now final.
    mutating func letGo(_ ids: [Item.ID], from line: inout [Item], now: Date) -> (token: Int?, finalized: [Item]) {
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
    mutating func undo(into line: inout [Item]) -> Bool {
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
    mutating func expire(token: Int) -> [Item] {
        guard let p = pending, p.token == token else { return [] }
        pending = nil
        return p.items.map(\.item)
    }

    func contains(_ id: Item.ID) -> Bool { pending?.items.contains { $0.item.id == id } ?? false }
}

#if canImport(Darwin)
    import Darwin

    /// Watches one folder with a vnode `DispatchSource` on an `O_EVTONLY` descriptor.
    final class FolderWatcher {
        enum Event { case contents, folderMoved, recheck }
        static let captureAttribute = "com.apple.metadata:kMDItemIsScreenCapture"
        static let recordingAttribute = "com.apple.metadata:kMDItemIsScreenRecording"

        let url: URL
        private let queue: DispatchQueue
        private let handler: (Event) -> Void
        private var source: DispatchSourceFileSystemObject?

        init(url: URL, queue: DispatchQueue, handler: @escaping (Event) -> Void) {
            self.url = url; self.queue = queue; self.handler = handler
        }

        deinit { stop() }

        /// False when the folder can't be opened (missing, or no permission yet for Desktop/Documents/Downloads).
        func start() -> Bool {
            guard source == nil else { return true }
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { return false }
            let s = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link], queue: queue)
            let handler = handler
            s.setEventHandler { [weak s] in
                guard let s else { return }
                handler(s.data.contains(.delete) || s.data.contains(.rename) ? .folderMoved : .contents)
            }
            s.setCancelHandler { close(fd) }
            source = s
            s.resume()
            return true
        }

        func stop() { source?.cancel(); source = nil }

        static func hasScreenCaptureFlag(_ url: URL) -> Bool {
            let path = url.path
            for name in [captureAttribute, recordingAttribute] where getxattr(path, name, nil, 0, 0, 0) >= 0 {
                return true
            }
            return false
        }

        /// The folder's direct children, hidden ones included (screencapture writes a dot-file, then renames it).
        static func entries(in dir: URL) -> [FolderScan.Entry] {
            let keys: Set<URLResourceKey> = [.creationDateKey, .isHiddenKey, .isRegularFileKey]
            guard
                let items = try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: Array(keys))
            else { return [] }
            return items.compactMap { u in
                let v = try? u.resourceValues(forKeys: keys)
                guard v?.isRegularFile == true else { return nil }
                return FolderScan.Entry(
                    name: u.lastPathComponent, created: v?.creationDate ?? .distantPast,
                    hidden: v?.isHidden ?? false, captureFlag: hasScreenCaptureFlag(u))
            }
        }
    }
#endif
// END clip plumbing
