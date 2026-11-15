import AppKit
import Combine
import PlannerCore
import PerchUI
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

protocol ScreenshotQuerying: AnyObject {
    var predicate: NSPredicate? { get set }
    var searchScopes: [Any] { get set }
    func start() -> Bool
    func stop()
}

extension NSMetadataQuery: ScreenshotQuerying {}

/// Durable file, image, link and text references for the drop shelf. Only explicit
/// drops add content. Stored capture preferences remain compatible but never start
/// screenshot watching or clipboard polling. Temporary files receive kept copies;
/// letting go remains undoable without deleting original files.
@MainActor
final class ClipsService: ObservableObject {
    struct Clip: Identifiable, Equatable {
        enum Content: Equatable { case file(URL), link(URL), text(String), image(Data) }
        var id = UUID()
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
            case .link(let url): return String(url.absoluteString.prefix(60))
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
    private let dragEligibility: (() -> Bool)?
    private var lastClipError: PerchAppError?
    private var archiveReadable = true
    private var shelfSession = DropShelfSession()
    private var dragBaseline = NSPasteboard(name: .drag).changeCount
    @Published private(set) var shelfVisible = false
    private var shelfStorage: ClipShelfFile { ClipShelfFile(vault: vault) }
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
        },
        dragEligibility: (() -> Bool)? = nil
    ) {
        self.store = store
        self.now = now
        self.scheduler = scheduler
        self.pasteboard = pasteboard
        self.clipOpener = clipOpener
        self.dragEligibility = dragEligibility
        self.queryFactory = queryFactory
        self.watcherFactory = watcherFactory
        self.folderEntries = folderEntries
        self.folderProvider = folderProvider
        self.folderQueue = folderQueue
        self.pasteboardCount = pasteboard.changeCount
        self.vault = store.file.url.deletingLastPathComponent().appendingPathComponent("Clips", isDirectory: true)
        // Capture preferences decode for compatibility, but no watcher or pasteboard
        // polling starts, even for a previously opted-in profile.
        loadShelf()
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
            model?.strips?.setShelfVisible(true)
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

    // MARK: Durable drop shelf

    private func loadShelf() {
        do {
            let saved = try shelfStorage.load()
            clips = saved.map { item in
                var clip = Clip(content: Self.content(item.content), source: "dropped", date: item.date)
                clip.id = item.id; clip.pinned = item.pinned; clip.origin = item.origin
                if case .image(let data) = clip.content { clip.thumbnail = NSImage(data: data) }
                return clip
            }
            for clip in clips { if case .file(let url) = clip.content { thumbnail(for: clip.id, url: url) } }
            // Existing kept copies are live references, not old unowned files.
            let storage = shelfStorage, keeping = shelfStorage.retainedPaths(saved)
            let cutoff = now().addingTimeInterval(-ClipVault.retention)
            DispatchQueue.global(qos: .utility).async {
                ClipVault.sweep(storage.vault, olderThan: cutoff, keeping: keeping)
            }
        } catch {
            archiveReadable = false
            reportClipError(error)
        }
    }

    private func persistShelf(_ values: [Clip]) -> Bool {
        guard archiveReadable else { return false }
        do {
            try shelfStorage.save(
                values.map { clip in
                    let content: ClipShelfFile.Content
                    switch clip.content {
                    case .file(let url): content = .file(url)
                    case .link(let url): content = .link(url)
                    case .text(let text): content = .text(text)
                    case .image(let data): content = .image(data)
                    }
                    return .init(
                        id: clip.id, content: content, date: clip.date, pinned: clip.pinned, origin: clip.origin)
                })
            clearClipError(); return true
        } catch {
            reportClipError(error); return false
        }
    }

    private static func content(_ value: ClipShelfFile.Content) -> Clip.Content {
        switch value {
        case .file(let url): return .file(url)
        case .link(let url): return .link(url)
        case .text(let text): return .text(text)
        case .image(let data): return .image(data)
        }
    }

    /// The controller delegates its old Clips-opening drag route here. This always
    /// consumes that route; ordinary pointer movement can never show the shelf.
    func routeShelfDrag(at point: CGPoint, model: NotchModel, screens: [CGDirectDisplayID: NotchScreenState]) -> Bool {
        let dragging = isEligibleDrag
        if dragging,
            let target = screens.values.first(where: {
                !$0.fullScreen
                    && (NotchLayout.contains($0.geometry.notchRect, pointer: point)
                        || (model.screenID == $0.id
                            && model.strips.map { NotchLayout.contains($0.bounds, pointer: point) } == true))
            })
        {
            if model.screenID != target.id {
                model.close(); model.screenID = target.id; model.geometry = target.geometry
            }
            if !shelfSession.visible { model.close() }
            updateShelf(dragging: true, pointerInside: true, model: model)
        } else {
            trackShelfPointer(at: point, model: model)
        }
        return true
    }

    func trackShelfPointer(at point: CGPoint, model: NotchModel) {
        let inside =
            model.strips.map { NotchLayout.contains($0.bounds, pointer: point) } == true
            || model.geometry.map { NotchLayout.contains($0.notchRect, pointer: point) } == true
        updateShelf(dragging: isEligibleDrag, pointerInside: inside, model: model)
        if NSEvent.pressedMouseButtons & 1 == 0 { dragBaseline = NSPasteboard(name: .drag).changeCount }
    }

    private var isEligibleDrag: Bool {
        if let dragEligibility { return dragEligibility() }
        let board = NSPasteboard(name: .drag)
        guard NSEvent.pressedMouseButtons & 1 != 0, board.changeCount != dragBaseline else { return false }
        return board.types?.contains { [.fileURL, .URL, .string, .png, .tiff].contains($0) } == true
    }

    private func updateShelf(dragging: Bool, pointerInside: Bool, model: NotchModel) {
        shelfSession.update(dragging: dragging, pointerInside: pointerInside)
        guard shelfVisible != shelfSession.visible else { return }
        shelfVisible = shelfSession.visible
        model.strips?.setShelfVisible(shelfVisible)
    }

    /// Choose a representation the source actually registered, in its fidelity
    /// order. Negotiated object conversions are not evidence that text is a URL.
    enum DropRepresentation: Equatable {
        case file(String), link(String), image(String), text(String)

        init?(identifiers: [String]) {
            for identifier in identifiers {
                guard let type = UTType(identifier) else { continue }
                if type.conforms(to: .fileURL) { self = .file(identifier); return }
                if type.conforms(to: .url) { self = .link(identifier); return }
                if type.conforms(to: .image) { self = .image(identifier); return }
                if type.conforms(to: .plainText) { self = .text(identifier); return }
            }
            return nil
        }
    }

    /// A successful provider load is the only input path. No background capture.
    @discardableResult
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let supported = providers.compactMap { provider -> (NSItemProvider, DropRepresentation)? in
            guard let representation = DropRepresentation(identifiers: provider.registeredTypeIdentifiers) else {
                return nil
            }
            return (provider, representation)
        }
        if !supported.isEmpty, let model { updateShelf(dragging: true, pointerInside: true, model: model) }
        for (provider, representation) in supported {
            switch representation {
            case .file:
                _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                    if let url { Task { @MainActor in self?.add(.file(url), source: "dropped") } }
                }
            case .link:
                _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                    if let url { Task { @MainActor in self?.add(.link(url), source: "dropped") } }
                }
            case .image(let identifier):
                provider.loadDataRepresentation(forTypeIdentifier: identifier) { [weak self] data, _ in
                    if let data { Task { @MainActor in self?.add(.image(data), source: "dropped") } }
                }
            case .text(let identifier):
                // Prefer the exact UTF-8 bytes over a bridged object conversion.
                if provider.registeredTypeIdentifiers.contains(UTType.utf8PlainText.identifier) {
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier) {
                        [weak self] data, _ in
                        if let data, let text = String(data: data, encoding: .utf8) {
                            Task { @MainActor in self?.add(.text(text), source: "dropped") }
                        }
                    }
                } else if identifier == UTType.utf16ExternalPlainText.identifier {
                    provider.loadDataRepresentation(forTypeIdentifier: identifier) { [weak self] data, _ in
                        if let data, let text = String(data: data, encoding: .utf16) {
                            Task { @MainActor in self?.add(.text(text), source: "dropped") }
                        }
                    }
                } else {
                    _ = provider.loadObject(ofClass: NSString.self) { [weak self] text, _ in
                        if let text = text as? String {
                            Task { @MainActor in self?.add(.text(text), source: "dropped") }
                        }
                    }
                }
            }
        }
        return !supported.isEmpty
    }

    func clearShelf() { letGo(clips.map(\.id)) }

    func dragProvider(for clip: Clip) -> NSItemProvider {
        switch clip.content {
        case .file(let kept):
            let url = clip.origin.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? kept
            return NSItemProvider(object: url as NSURL)
        case .link(let url): return NSItemProvider(object: url as NSURL)
        case .text(let text):
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) {
                completion in
                completion(Data(text.utf8), nil); return nil
            }
            return provider
        case .image(let data):
            if let image = NSImage(data: data) { return NSItemProvider(object: image) }
            return NSItemProvider()
        }
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
        guard archiveReadable else { return }
        if case .file(let url) = content, Self.canonicalPath(url) == Self.canonicalPath(shelfStorage.url) { return }
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
        var next = clips
        next.insert(clip, at: 0)
        var fell: [Clip] = []
        while next.count > Self.capacity, let i = next.lastIndex(where: { !$0.pinned }) {
            fell.append(next.remove(at: i))
        }
        guard persistShelf(next) else { return }
        clips = next
        discard(fell)
        if case .file(let u) = content { thumbnail(for: clip.id, url: u) }
    }

    // Retained for the baseline view compiled by the before/after CI probe.
    func remove(_ id: UUID) { letGo(id) }

    func clearUnpinned() {
        let removed = clips.filter { !$0.pinned }
        let next = clips.filter(\.pinned)
        guard persistShelf(next) else { return }
        clips = next
        discard(removed)
    }

    func togglePin(_ id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        var next = clips; next[i].pinned.toggle()
        if persistShelf(next) { clips = next }
    }

    /// Takes clips off the line. `undoLetGo()` brings the latest batch back within `LetGoLedger.window` seconds.
    func letGo(_ ids: [UUID]) {
        var next = clips, nextLedger = ledger
        let r = nextLedger.letGo(ids, from: &next, now: now())
        guard persistShelf(next) else { return }
        ledger = nextLedger; clips = next
        discard(r.finalized)
        guard let token = r.token, let p = ledger.pending else { return }
        Motion.animate(Motion.token(.hover)) {
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
        var next = clips, nextLedger = ledger
        guard nextLedger.undo(into: &next), persistShelf(next) else { return }
        ledger = nextLedger; clips = next
        letGoWork?.cancel()
        letGoWork = nil
        Motion.animate(Motion.token(.hover)) { letGoBanner = nil }
        debugLog("undo")
    }

    private func expireLetGo(_ token: Int) {
        discard(ledger.expire(token: token))
        if letGoBanner?.token == token { Motion.animate(Motion.token(.hover)) { letGoBanner = nil } }
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
        case .link(let url): pb.replace(with: .text(url.absoluteString))
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
