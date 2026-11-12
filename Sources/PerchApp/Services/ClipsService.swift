import AppKit
import Combine
import PlannerCore
import PerchUI
import QuickLookThumbnailing
import SwiftUI

protocol ScreenshotQuerying: AnyObject {
    var predicate: NSPredicate? { get set }
    var searchScopes: [Any] { get set }
    func start() -> Bool
    func stop()
}

extension NSMetadataQuery: ScreenshotQuerying {}

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

        var title: String { localizedTitle() }

        func localizedTitle(locale: Locale? = nil) -> String {
            switch content {
            case .file(let u): return u.lastPathComponent
            case .text(let s): return String(s.prefix(60))
            case .image: return AppL10n.text("Copied image", locale: locale)
            }
        }

        func displayTitle(copied: Bool, locale: Locale? = nil) -> String {
            copied ? AppL10n.text("Copied", locale: locale) : localizedTitle(locale: locale)
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

        var diagnosticName: String {
            switch self {
            case .off: "off"
            case .watching: "watching"
            case .unreadable: "unreadable"
            }
        }
    }

    static let capacity = 12
    typealias QueryFactory = () -> any ScreenshotQuerying
    typealias WatcherFactory = (URL, DispatchQueue, @escaping FolderWatcher.Handler) -> any FolderWatching
    typealias FolderEntries = @Sendable (URL) -> [FolderScan.Entry]
    typealias ClipOpener = (URL, @escaping @Sendable (Error?) -> Void) -> Void
    @Published private(set) var clips: [Clip] = []
    @Published private(set) var letGoBanner: LetGoBanner?
    @Published private(set) var folderWatch: FolderWatch = .off
    let store: PlannerStore
    weak var model: NotchModel?
    /// Application Support/Perch/Clips, next to planner.json (so `PERCH_DATA` relocates it too).
    let vault: URL
    private let now: () -> Date
    private let scheduler: any AppScheduling
    private let pasteboard: any PasteboardAccess
    private let clipOpener: ClipOpener
    private var lastClipError: PerchAppError?
    @MainActor
    private final class LifetimeState {
        var letGoWork: (any AppScheduledAction)?
        var demoWork: (any AppScheduledAction)?
        var recheckTask: Task<Void, Never>?
    }
    private let lifetimeState = MainActorLifetime(LifetimeState()) { state in
        state.demoWork?.cancel(); state.recheckTask?.cancel(); state.letGoWork?.cancel()
    }
    private var letGoWork: (any AppScheduledAction)? {
        get { lifetimeState.state.letGoWork }
        set { lifetimeState.state.letGoWork = newValue }
    }
    private var demoWork: (any AppScheduledAction)? {
        get { lifetimeState.state.demoWork }
        set { lifetimeState.state.demoWork = newValue }
    }
    private var recheckTask: Task<Void, Never>? {
        get { lifetimeState.state.recheckTask }
        set { lifetimeState.state.recheckTask = newValue }
    }

    private var query: (any ScreenshotQuerying)?
    private var queryObserver: NSObjectProtocol?
    private var startedAt = Date()
    private var watcher: (any FolderWatching)?
    private var folder: ScreenshotFolder.Resolved?
    private var scan: FolderScan?
    private var folderCheckTimer: Timer?
    private let folderQueue: DispatchQueue
    private let queryFactory: QueryFactory
    private let watcherFactory: WatcherFactory
    private let folderEntries: FolderEntries
    private let folderProvider: (() -> ScreenshotFolder.Resolved)?
    private var watchGeneration = 0
    private var watchStarting = false
    /// Every path a capture source already reported, so Spotlight catching up later never hangs a clip twice.
    private var caughtPaths = Set<String>()
    private var ledger = LetGoLedger<Clip>()
    private var pasteboardCount: Int
    private var pasteTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(
        store: PlannerStore, now: @escaping () -> Date = Date.init,
        scheduler: any AppScheduling = MainQueueScheduler(),
        pasteboard: any PasteboardAccess = NSPasteboard.general, monitoring: Bool = true,
        queryFactory: @escaping QueryFactory = { NSMetadataQuery() },
        watcherFactory: @escaping WatcherFactory = { url, queue, handler in
            FolderWatcher(url: url, queue: queue, handler: handler)
        },
        folderEntries: @escaping FolderEntries = FolderWatcher.entries,
        folderProvider: (() -> ScreenshotFolder.Resolved)? = nil,
        folderQueue: DispatchQueue = DispatchQueue(label: "perch.clips.folder", qos: .utility),
        clipOpener: @escaping ClipOpener = { url, completion in
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                completion(error)
            }
        }
    ) {
        self.store = store
        self.now = now
        self.scheduler = scheduler
        self.pasteboard = pasteboard
        self.clipOpener = clipOpener
        self.queryFactory = queryFactory
        self.watcherFactory = watcherFactory
        self.folderEntries = folderEntries
        self.folderProvider = folderProvider
        self.folderQueue = folderQueue
        self.pasteboardCount = pasteboard.changeCount
        self.vault = store.file.url.deletingLastPathComponent().appendingPathComponent("Clips", isDirectory: true)
        guard monitoring else { return }
        store.$planner.map(\.preferences.catchScreenshots).removeDuplicates().sink { [weak self] on in
            on ? self?.startScreenshots() : self?.stopScreenshots()
        }.store(in: &cancellables)
        store.$planner.map(\.preferences.catchCopies).removeDuplicates().sink { [weak self] on in
            on ? self?.startPasteboard() : self?.stopPasteboard()
        }.store(in: &cancellables)
        // The line is not persisted, so kept copies from earlier runs are orphans once they age out.
        let vault = vault
        let cutoff = now().addingTimeInterval(-ClipVault.retention)
        DispatchQueue.global(qos: .utility).async {
            ClipVault.sweep(vault, olderThan: cutoff, keeping: [])
        }
        #if DEBUG || PERCH_TESTING
            if Self.demo {
                demoWork = scheduler.schedule(after: 0.8) { [weak self] in self?.seedDemo() }
            }
        #endif
    }

    #if DEBUG || PERCH_TESTING
        /// `--demo-clips` (screenshots, real-Mac checks): a temp file gets kept, one clip is let go, Clips opens with the toast.
        private func seedDemo() {
            let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Perch demo clip.txt")
            try? Data("Kept out of a temporary folder.".utf8).write(to: temp)
            add(.file(temp), source: "dropped")
            add(.text("https://example.com/launch-checklist"), source: "copied")
            add(.text("Ship notes: folder watch, kept copies, undo"), source: "copied")
            if let first = clips.first { letGo(first.id) }
            debugLog("seeded kept=\(clips.compactMap(\.content.fileURL).count)")
            model?.open(page: .clips, pinned: true)
        }

        private static let demo = CommandLine.arguments.contains("--demo-clips")
    #endif

    private func debugLog(_ event: String) {
        #if DEBUG || PERCH_TESTING
            guard Self.demo else { return }
            FileHandle.standardError.write(
                Data(
                    "clips: \(event) | line=\(clips.count) pending=\(letGoBanner?.count ?? 0) watch=\(folderWatch.diagnosticName)\n"
                        .utf8))
        #endif
    }

    // MARK: Screenshots

    private func startScreenshots() {
        guard query == nil else { return }
        startedAt = now()
        // Spotlight: no permission needed, but indexing can lag.
        let q = queryFactory()
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
        #if DEBUG || PERCH_TESTING
            if let override = ProcessInfo.processInfo.environment["PERCH_SCREENSHOT_FOLDER"] { return override }
        #endif
        let domain = "com.apple.screencapture" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("location" as CFString, domain) as? String
    }

    private func currentFolder() -> ScreenshotFolder.Resolved {
        if let folderProvider { return folderProvider() }
        return ScreenshotFolder.resolve(
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
        let since = now()
        let entries = folderEntries
        let w = watcherFactory(resolved.url, folderQueue) { [weak self] reason in
            let entries = entries(resolved.url)
            Task { @MainActor in self?.folderChanged(entries, reason: reason, folder: resolved) }
        }
        watchStarting = true
        // Opening Desktop/Documents/Downloads can wait on the privacy prompt: never on the main thread.
        folderQueue.async { [weak self] in
            let ok = w.start()
            let existing = ok ? Set(entries(resolved.url).map(\.name)) : []
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
            recheckTask?.cancel()
            recheckTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                let entries = self.folderEntries
                let later = await Task.detached { entries(resolved.url) }.value
                guard !Task.isCancelled else { return }
                self.recheckTask = nil
                self.folderChanged(later, reason: .recheck, folder: resolved)
            }
        }
    }

    /// A capture source found a new screenshot or recording.
    private func caught(_ url: URL) {
        guard caughtPaths.insert(Self.canonicalPath(url)).inserted else { return }
        add(.file(url), source: "captured")
        debugLog("capture accepted")
    }

    // MARK: Pasteboard

    private func startPasteboard() {
        guard pasteTimer == nil else { return }
        pasteboardCount = pasteboard.changeCount
        pasteTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPasteboard() }
        }
    }

    private func stopPasteboard() { pasteTimer?.invalidate(); pasteTimer = nil }

    private func pollPasteboard() {
        let pb = pasteboard
        guard pb.changeCount != pasteboardCount else { return }
        pasteboardCount = pb.changeCount
        // Respect password managers and transient copies (nspasteboard.org conventions).
        let skip = [
            "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        ]
        if pb.declaredTypes.contains(where: { skip.contains($0) }) { return }
        if let u = pb.fileURLs.first {
            add(.file(u), source: "copied")
        } else if let img = pb.imageData {
            add(.image(img), source: "copied")
        } else if let s = pb.plainText, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
            // A temp file disappears soon: keep a durable copy, or leave the drop retryable.
            if ClipVault.isTemporary(u) {
                do {
                    let kept = try ClipVault.keepCopy(of: u, in: vault, now: now())
                    origin = u
                    content = .file(kept)
                    clearClipError()
                } catch {
                    reportClipError(error)
                    return
                }
            }
        } else if clips.contains(where: { $0.content == content }) {
            return
        }
        var clip = Clip(content: content, source: source, date: now())
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
        let r = ledger.letGo(ids, from: &clips, now: now())
        discard(r.finalized)
        guard let token = r.token, let p = ledger.pending else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            letGoBanner = LetGoBanner(token: token, count: p.items.count, deadline: p.deadline)
        }
        letGoWork?.cancel()
        letGoWork = scheduler.schedule(after: LetGoLedger<Clip>.window) { [weak self] in
            self?.expireLetGo(token)
        }
        debugLog("let go \(p.items.count)")
    }

    func letGo(_ id: UUID) { letGo([id]) }

    /// Lets go of every unpinned clip at once, undoable as one step.
    func sweep() { letGo(clips.filter { !$0.pinned }.map(\.id)) }

    func undoLetGo() {
        guard ledger.undo(into: &clips) else { return }
        letGoWork?.cancel()
        letGoWork = nil
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
        let pb = pasteboard
        switch clip.content {
        case .file(let u): pb.replace(with: .file(u))
        case .text(let s): pb.replace(with: .text(s))
        case .image(let d): pb.replace(with: .image(d))
        }
        pasteboardCount = pb.changeCount  // don't re-catch our own copy
    }

    func open(_ clip: Clip) {
        guard case .file(let u) = clip.content else { return }
        clipOpener(u) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.reportClipError(error) } else { self.clearClipError() }
            }
        }
    }

    private func reportClipError(_ error: Error) {
        let failure = PerchAppError.planner(error.perchPresentationDetail)
        lastClipError = failure
        store.lastError = failure
    }

    private func clearClipError() {
        guard let lastClipError else { return }
        if store.lastError == lastClipError { store.lastError = nil }
        self.lastClipError = nil
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
