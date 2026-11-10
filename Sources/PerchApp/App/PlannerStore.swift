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
    private var visibleDayOffsets = [0]
    private var lastSeenModification: Date?
    private var loadFailureMessage: String?
    private var loadNeedsRetry = false
    private var pollTimer: Timer?
    private var saveWork: (any AppScheduledAction)?

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
        self.pipeline = PlannerCommandPipeline(file: file, clock: ClosurePlannerClock(now))
        self.now = now
        self.scheduler = scheduler
        var loaded = Planner()
        var loadError: String?
        do { loaded = try file.load() } catch let recovery as PlannerRecoveryError {
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
        lastSeenModification = file.modificationDate
        if watching {
            startWatching()
            DistributedNotificationCenter.default().addObserver(
                forName: .init("app.perch.mac.plannerChanged"), object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.reloadFromDisk(external: true) } }
        }
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
        if send(.lifecycle(.launch), origin: .background) != nil { lifecycleDay = today }
        renewReminderHorizon()
    }

    func openDay(_ day: DayKey) {
        send(.lifecycle(.openDay(day)), origin: .background)
    }

    func advanceLifecycle() {
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
        renewReminderHorizon()
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
        planner = saved
        // A writer may run immediately after our lock is released. Recheck on the next poll
        // rather than associating its modification date with our earlier snapshot.
        lastSeenModification = nil
        lastError = nil
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
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reloadFromDisk(external: true); self?.advanceLifecycle()
            }
        }
    }

    func reloadFromDisk(external: Bool) {
        let mod = file.modificationDate
        guard mod != lastSeenModification || loadNeedsRetry else { return }
        do {
            let fresh = try file.load()
            lastSeenModification = mod
            loadNeedsRetry = false
            if let failure = loadFailureMessage, lastError == failure { lastError = nil }
            loadFailureMessage = nil
            guard fresh != planner else { return }
            // External edits and link updates never become local undo steps or clear redo.
            planner = fresh
            if external { NotificationCenter.default.post(name: .plannerChangedExternally, object: nil) }
        } catch let recovery as PlannerRecoveryError {
            lastSeenModification = mod
            loadNeedsRetry = false
            loadFailureMessage = recovery.localizedDescription
            lastError = loadFailureMessage
            guard recovery.recoveredPlanner != planner else { return }
            planner = recovery.recoveredPlanner
            if external { NotificationCenter.default.post(name: .plannerChangedExternally, object: nil) }
        } catch {
            // Access may be repaired without changing the file's modification date.
            // Retain the last visible document and retry, never publish an empty replacement.
            loadNeedsRetry = true
            report(error)
            loadFailureMessage = lastError
        }
    }
}

extension Notification.Name {
    static let plannerChangedExternally = Notification.Name("PerchPlannerChangedExternally")
    static let perchOpenWorkspace = Notification.Name("PerchOpenWorkspace")
}
