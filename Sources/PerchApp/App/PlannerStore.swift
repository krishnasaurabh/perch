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
    private var history = PlannerUndoHistory()
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

        func set(_ text: String, in planner: inout Planner) {
            switch self {
            case .title(let id):
                if let i = planner.tasks.firstIndex(where: { $0.id == id }) { planner.tasks[i].title = text }
            case .notes(let id):
                if let i = planner.tasks.firstIndex(where: { $0.id == id }) { planner.tasks[i].notes = text }
            case .notepad(let day):
                if let i = planner.notes.firstIndex(where: { $0.day == day }) {
                    planner.notes[i].text = text
                } else {
                    planner.notes.append(QuickNote(day: day, text: text))
                }
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
    func apply<T>(_ body: (inout PlannerEngine) throws -> T) -> T? {
        guard flushPendingText() else { return nil }
        return performMutation(tracked: true, body)
    }

    /// Shared by user edits and background bookkeeping; publish only after the atomic write succeeds.
    @discardableResult
    func performMutation<T>(tracked: Bool, _ body: (inout PlannerEngine) throws -> T) -> T? {
        do {
            let (result, before, after): (T, Planner, Planner) = try file.mutate { p in
                let before = p
                var e = PlannerEngine(planner: p, now: now)
                let result = try body(&e)
                p = e.planner
                return (result, before, p)
            }
            if tracked { history.record(before: before, after: after) }
            publish(after)
            return result
        } catch {
            report(error)
            return nil
        }
    }

    func updatePrefs(_ body: (inout Preferences) -> Void) {
        apply { e in body(&e.planner.preferences) }
    }

    func updateTask(_ id: UUID, _ body: (inout PlanTask) -> Void) {
        apply { e in
            guard let i = e.planner.tasks.firstIndex(where: { $0.id == id }) else { return }
            body(&e.planner.tasks[i])
        }
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
            let (before, after) = try file.mutate { p in
                let before = p
                for (target, draft) in drafts {
                    guard let current = target.value(in: p), current == draft.base || current == draft.text else {
                        throw PlannerError(
                            "This text changed elsewhere. Your draft is retained; restore the shared text before retrying."
                        )
                    }
                    target.set(draft.text, in: &p)
                }
                return (before, p)
            }
            history.record(before: before, after: after)
            pendingText.removeAll()
            publish(after)
            return true
        } catch {
            report(error)
            return false
        }
    }

    // MARK: Undo

    var canUndo: Bool { history.canUndo || !pendingText.isEmpty }
    var canRedo: Bool { history.canRedo }

    func undo() { traverseHistory(redo: false) }
    func redo() { traverseHistory(redo: true) }

    private func traverseHistory(redo: Bool) {
        guard flushPendingText() else { return }
        guard redo ? history.canRedo : history.canUndo else { NSSound.beep(); return }
        do {
            var saved: Planner?
            let transaction: ((inout Planner) -> Void) throws -> Void = { change in
                saved = try self.file.mutate { p in
                    change(&p); return p
                }
            }
            if redo { try history.redo(transaction: transaction) } else { try history.undo(transaction: transaction) }
            if let saved { publish(saved) }
        } catch { report(error) }
    }

    // MARK: External refresh

    private func startWatching() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reloadFromDisk(external: true); self?.refreshToday()
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
