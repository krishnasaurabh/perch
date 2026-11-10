import AppKit
import Combine
import PlannerCore
import SwiftUI

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }
    static var executablePath: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }
    static var isInApplications: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }
}

/// The planner as the UI sees it. Every mutation reads the latest document under its file lock.
@MainActor
final class PlannerStore: ObservableObject {
    @Published private(set) var planner: Planner { didSet { refreshToday() } }
    @Published var lastError: String?
    @Published private(set) var today: DayKey
    let file: PlannerFile
    private let now: () -> Date
    private let scheduler: any AppScheduling
    private let pipeline: PlannerCommandPipeline
    private var lifecycleDay: DayKey?
    private var needsLaunch = false
    private var visibleDayOffsets = [0]
    private var loadFailureMessage: String?
    private var loadNeedsRetry = false
    private var recoveryTimer: Timer?
    private var saveWork: (any AppScheduledAction)?
    private var reloadWork: (any AppScheduledAction)?
    private var focusWork: (any AppScheduledAction)?
    private var dayWork: (any AppScheduledAction)?
    private var observer: PlannerDirectoryObserver?
    private let runtimeIO = PlannerRuntimeIO()
    private var observationTokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var revision: PlannerFileRevision?
    private var epoch = 0
    private var reloadInFlight = false
    private var reloadAgain = false
    private var tickInFlight = false
    private var runtimeEnabled = false
    var focusFinished: (() -> Void)?

    enum TextTarget: Hashable {
        case title(UUID), notes(UUID), notepad(DayKey)

        func value(in planner: Planner) -> String? {
            switch self {
            case .title(let id): return planner.tasks.first { $0.id == id }?.title
            case .notes(let id): return planner.tasks.first { $0.id == id }?.notes
            case .notepad(let day): return planner.notes.first { $0.day == day }?.text ?? ""
            }
        }

        func apply(_ text: String, using commands: PlannerCommands) throws {
            switch self {
            case .title(let id):
                var edit = TaskChanges(); edit.title = .set(text)
                try commands.execute(.editTask(id, edit))
            case .notes(let id):
                var edit = TaskChanges(); edit.notes = .set(text)
                try commands.execute(.editTask(id, edit))
            case .notepad(let day):
                try commands.writeNotepad(on: day, text: text, mode: "replace")
            }
        }
    }

    private struct PendingText {
        let base: String
        var text: String
    }
    @Published private var pendingText: [TextTarget: PendingText] = [:]

    init(
        file: PlannerFile = PlannerFile(), now: @escaping () -> Date = Date.init, watching: Bool = true,
        scheduler: any AppScheduling = MainQueueScheduler()
    ) {
        self.file = file
        self.pipeline = PlannerCommandPipeline(file: file.avoidingLockWaits(), clock: ClosurePlannerClock(now))
        self.now = now
        self.scheduler = scheduler
        var loaded = Planner()
        var loadError: String?
        do { loaded = try file.avoidingLockWaits().load() } catch let recovery as PlannerRecoveryError {
            // The file remains authoritative and rejects every mutation until repaired.
            // Display the validated draft without publishing or saving it as a new revision.
            loaded = recovery.recoveredPlanner
            loadError = recovery.localizedDescription
        } catch {
            loadError = (error as? PlannerError)?.message ?? error.localizedDescription
            loadNeedsRetry = true
        }
        loadFailureMessage = loadError
        planner = loaded
        today = PlannerEngine(planner: loaded, now: now).today
        lastError = loadError
        revision = PlannerFileRevision(url: file.url)
        if watching { startWatching() }
    }

    var engine: PlannerEngine { PlannerEngine(planner: planner, now: now) }
    var prefs: Preferences { planner.preferences }
    func dayKey(_ date: Date) -> DayKey { engine.dayKey(date) }
    var capture: TaskCapture { TaskCapture(now: now(), resetHour: prefs.resetHour) }

    private func refreshToday() {
        let t = engine.today
        if t != today { today = t }
    }

    // MARK: Mutations

    @discardableResult
    func apply<T>(_ body: (PlannerCommands) throws -> T) -> T? {
        guard flushPendingText() else { return nil }
        return performMutation(origin: .user, body)
    }

    @discardableResult
    func send(_ action: PlannerAction, origin: PlannerCommandOrigin = .user) -> PlannerActionResult? {
        if origin == .user && !flushPendingText() { return nil }
        return performMutation(origin: origin) { try $0.execute(action) }
    }

    @discardableResult
    func performMutation<T>(origin: PlannerCommandOrigin, _ body: (PlannerCommands) throws -> T) -> T? {
        do {
            let result = try pipeline.perform(origin: origin, body)
            publish(result.state)
            return result.value
        } catch {
            report(error)
            return nil
        }
    }

    func updatePrefs(_ body: (inout Preferences) -> Void) {
        apply { try $0.updatePrefs(body) }
    }

    func updateTask(_ id: UUID, _ body: (inout PlanTask) -> Void) {
        apply { try $0.updateTask(id, body) }
    }

    /// Called by application launch/navigation, never by view appearance or arbitrary publications.
    func beginApplication() {
        needsLaunch = true
        if send(.lifecycle(.launch), origin: .background) != nil {
            lifecycleDay = today
            needsLaunch = false
        }
    }

    func openDay(_ day: DayKey) {
        send(.lifecycle(.openDay(day)), origin: .background)
    }

    func advanceLifecycle() {
        if needsLaunch { beginApplication(); return }
        refreshToday()
        guard lifecycleDay != today else { return }
        let result = performMutation(origin: .background) { commands in
            try commands.execute(.lifecycle(.dayChanged))
            for offset in visibleDayOffsets {
                let day = commands.today.adding(days: offset, calendar: commands.read.calendar)
                try commands.execute(.lifecycle(.openDay(day)))
            }
        }
        if result != nil { lifecycleDay = today }
    }

    func materializeRepeats(on days: [DayKey]) {
        let calendar = engine.calendar
        visibleDayOffsets = days.map {
            calendar.dateComponents([.day], from: today.date(calendar: calendar), to: $0.date(calendar: calendar)).day
                ?? 0
        }
        let priorError = lastError
        let result = performMutation(origin: .background) { commands in
            for day in days { try commands.execute(.lifecycle(.openDay(day))) }
        }
        if result != nil { lastError = priorError }
    }

    private func publish(_ saved: Planner) {
        epoch += 1
        if planner != saved { planner = saved }
        // Do not associate a post-lock revision with a snapshot from before the lock was released.
        revision = nil
        lastError = nil
        scheduleBoundaries()
        if runtimeEnabled { requestReload() }
    }

    private func report(_ error: Error) {
        lastError = (error as? PlannerError)?.message ?? error.localizedDescription
    }

    // MARK: Coalesced text

    func text(for target: TextTarget) -> String {
        pendingText[target]?.text ?? target.value(in: planner) ?? ""
    }

    /// Keep the draft in the store, not the lifetime of a view. A typing burst is one durable edit.
    func setText(_ text: String, for target: TextTarget) {
        guard let base = pendingText[target]?.base ?? target.value(in: planner) else { return }
        if text == base { pendingText[target] = nil } else { pendingText[target] = PendingText(base: base, text: text) }
        saveWork?.cancel()
        saveWork = scheduler.schedule(after: 0.5) { [weak self] in self?.flushPendingText() }
    }

    /// Also called on blur, view removal and termination. Failures retain every draft for retry.
    @discardableResult
    func flushPendingText() -> Bool {
        saveWork?.cancel()
        saveWork = nil
        guard !pendingText.isEmpty else { return true }
        let drafts = pendingText
        do {
            let result = try pipeline.perform(origin: .user) { commands in
                for (target, draft) in drafts {
                    guard let current = target.value(in: commands.planner),
                        current == draft.base || current == draft.text
                    else {
                        throw PlannerError(
                            "This text changed elsewhere. Your draft is retained; restore the shared text before retrying."
                        )
                    }
                    try target.apply(draft.text, using: commands)
                }
            }
            pendingText.removeAll()
            publish(result.state)
            return true
        } catch {
            report(error)
            return false
        }
    }

    // MARK: Undo

    var canUndo: Bool { pipeline.canUndo || !pendingText.isEmpty }
    var canRedo: Bool { pipeline.canRedo }

    func undo() { traverseHistory(redo: false) }
    func redo() { traverseHistory(redo: true) }

    private func traverseHistory(redo: Bool) {
        guard flushPendingText() else { return }
        guard redo ? pipeline.canRedo : pipeline.canUndo else { NSSound.beep(); return }
        do {
            let saved = try redo ? pipeline.redo() : pipeline.undo()
            if let saved { publish(saved) }
        } catch { report(error) }
    }

    // MARK: External refresh

    private func startWatching() {
        runtimeEnabled = true
        observer = PlannerDirectoryObserver(url: file.url) { [weak self] in self?.requestReload() }
        observe(DistributedNotificationCenter.default(), .init("app.perch.mac.plannerChanged")) {
            $0.requestReload()
        }
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            observe(.default, name) { $0.clockChanged() }
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { $0.clockChanged() }
        // Filesystems can revoke watches; permissions can recover without a content change.
        // This metadata-only safety net also reinstalls watches after a missing directory returns.
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recoverObservation()
            }
        }
        recoveryTimer?.tolerance = 5
        scheduleBoundaries()
        requestReload()
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name,
        action: @escaping (PlannerStore) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if let self { action(self) } }
        }
        observationTokens.append((center, token))
    }

    deinit {
        recoveryTimer?.invalidate()
        for (center, token) in observationTokens { center.removeObserver(token) }
        reloadWork?.cancel(); focusWork?.cancel(); dayWork?.cancel(); saveWork?.cancel()
    }

    private func clockChanged() {
        observer?.repair()
        requestReload()
        advanceLifecycle()
        scheduleBoundaries()
    }

    private func scheduleBoundaries() {
        guard runtimeEnabled else { return }
        focusWork?.cancel(); dayWork?.cancel()
        let time = now()
        if let next = FocusUpdateSchedule.nextUpdate(for: planner.focus, now: time) {
            focusWork = scheduler.schedule(after: max(0.05, next.timeIntervalSince(time))) { [weak self] in
                self?.persistFocusBoundary()
            }
        }
        let nextDay = FocusUpdateSchedule.nextDay(for: planner, now: time)
        dayWork = scheduler.schedule(after: max(0.05, nextDay.timeIntervalSince(time))) { [weak self] in
            self?.advanceLifecycle()
            self?.scheduleBoundaries()
        }
    }

    private func persistFocusBoundary() {
        guard !tickInFlight else { return }
        tickInFlight = true
        let generation = epoch
        runtimeIO.tick(file, at: now()) { [weak self] result in
            guard let self else { return }
            self.tickInFlight = false
            if generation == self.epoch {
                switch result {
                case .success(let change):
                    self.publish(change.state)
                    if change.value.flag { self.focusFinished?() }
                case .failure(let error):
                    self.report(error)
                    // Retry a failed write without a tight loop and without dropping its checkpoint.
                    self.focusWork = self.scheduler.schedule(after: 1) { [weak self] in
                        self?.persistFocusBoundary()
                    }
                }
            } else {
                self.requestReload()
                self.scheduleBoundaries()
            }
        }
    }

    func recoverObservation() {
        observer?.repair()
        requestReload()
    }

    /// Notification and vnode bursts share one bounded reload, never one main-thread decode per event.
    func requestReload() {
        guard reloadWork == nil else { return }
        reloadWork = scheduler.schedule(after: 0.1) { [weak self] in
            guard let self else { return }
            self.reloadWork = nil
            if self.reloadInFlight { self.reloadAgain = true; return }
            self.reloadInFlight = true
            let generation = self.epoch
            self.runtimeIO.load(self.file, after: self.revision, force: self.loadNeedsRetry) {
                [weak self] revision, result in
                guard let self else { return }
                self.reloadInFlight = false
                if generation == self.epoch {
                    self.revision = revision
                    if let result { self.acceptReload(result, external: true) }
                } else {
                    self.reloadAgain = true
                }
                if self.reloadAgain {
                    self.reloadAgain = false
                    self.requestReload()
                }
            }
        }
    }

    private func acceptReload(_ result: Result<Planner, Error>, external: Bool) {
        switch result {
        case .success(let fresh):
            loadNeedsRetry = false
            if let failure = loadFailureMessage, lastError == failure { lastError = nil }
            loadFailureMessage = nil
            if fresh != planner {
                let completedFocus =
                    planner.focus?.state == .running && fresh.focus?.state == .finished
                    && planner.focus?.startedAt == fresh.focus?.startedAt
                    && planner.focus?.taskID == fresh.focus?.taskID
                    && fresh.focus?.limit != nil && fresh.focus?.isOver(at: now()) == true
                epoch += 1
                planner = fresh
                if completedFocus { focusFinished?() }
                if external { NotificationCenter.default.post(name: .plannerChangedExternally, object: nil) }
            }
        case .failure(let recovery as PlannerRecoveryError):
            loadNeedsRetry = false
            loadFailureMessage = recovery.localizedDescription
            lastError = loadFailureMessage
            if recovery.recoveredPlanner != planner {
                epoch += 1
                planner = recovery.recoveredPlanner
                if external { NotificationCenter.default.post(name: .plannerChangedExternally, object: nil) }
            }
        case .failure(let error):
            loadNeedsRetry = true
            report(error)
            loadFailureMessage = lastError
        }
        if runtimeEnabled && (lifecycleDay != nil || needsLaunch) { advanceLifecycle() }
        scheduleBoundaries()
    }

    /// Explicit refresh for import/diagnostic callers. Automatic observation uses background I/O.
    func reloadFromDisk(external: Bool) {
        let current = PlannerFileRevision(url: file.url)
        guard current != revision || loadNeedsRetry else { return }
        revision = current
        epoch += 1
        acceptReload(Result { try file.avoidingLockWaits().load() }, external: external)
    }
}

extension Notification.Name {
    static let plannerChangedExternally = Notification.Name("PerchPlannerChangedExternally")
    static let perchOpenWorkspace = Notification.Name("PerchOpenWorkspace")
}
