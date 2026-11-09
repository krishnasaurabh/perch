import AppKit
import Combine
import PlannerCore
import SwiftUI

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0" }
    static var executablePath: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }
    static var isInApplications: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }
}

/// The planner as the UI sees it. Every change goes through `PlannerEngine` and a locked write,
/// coordinating file writes between the app and MCP server process.
@MainActor
final class PlannerStore: ObservableObject {
    @Published private(set) var planner: Planner { didSet { refreshToday() } }
    @Published var lastError: String?
    /// The planner's logical day. It follows `Preferences.resetHour`, so 1 AM with "Day ends at 4 AM"
    /// is still yesterday. Published so views redraw when the day rolls over or the hour setting changes.
    @Published private(set) var today: DayKey
    let file: PlannerFile

    private var undoStack: [Planner] = []
    private var redoStack: [Planner] = []
    private var watcher: DispatchSourceFileSystemObject?
    private var lastSeenModification: Date?
    private var pollTimer: Timer?

    init(file: PlannerFile = PlannerFile()) {
        self.file = file
        var loaded = Planner()
        var loadError: String?
        do { loaded = try file.load() } catch {
            loadError = (error as? PlannerError)?.message ?? error.localizedDescription
        }
        planner = loaded
        today = PlannerEngine(planner: loaded).today
        lastError = loadError
        lastSeenModification = file.modificationDate
        startWatching()
        DistributedNotificationCenter.default().addObserver(
            forName: .init("app.perch.mac.plannerChanged"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reloadFromDisk(external: true) } }
    }

    var engine: PlannerEngine { PlannerEngine(planner: planner) }
    var prefs: Preferences { planner.preferences }

    /// The planner day a moment belongs to (honours the reset hour). Use instead of `DayKey(date)`.
    func dayKey(_ date: Date) -> DayKey { engine.dayKey(date) }
    /// Natural-language capture that agrees with `today`. Use instead of `TaskCapture()`.
    var capture: TaskCapture { TaskCapture(now: Date(), resetHour: prefs.resetHour) }

    private func refreshToday() {
        let t = engine.today
        if t != today { today = t }
    }

    // MARK: Mutations

    /// Applies a change through the engine. Errors land in `lastError` and are returned.
    @discardableResult
    func apply<T>(_ body: (inout PlannerEngine) throws -> T) -> T? {
        do {
            let before = planner
            let result: T = try file.mutate { p in
                var e = PlannerEngine(planner: p)
                let r = try body(&e)
                p = e.planner
                return r
            }
            let after = try file.load()
            if after != before { pushUndo(before) }
            planner = after
            lastSeenModification = file.modificationDate
            lastError = nil
            return result
        } catch {
            lastError = (error as? PlannerError)?.message ?? error.localizedDescription
            NSSound.beep()
            return nil
        }
    }

    func updatePrefs(_ body: (inout Preferences) -> Void) {
        apply { e in body(&e.planner.preferences) }
    }

    /// Direct edit of a task by id (details editor, drag and drop).
    func updateTask(_ id: UUID, _ body: (inout PlanTask) -> Void) {
        apply { e in
            guard let i = e.planner.tasks.firstIndex(where: { $0.id == id }) else { return }
            body(&e.planner.tasks[i])
        }
    }

    // MARK: Undo

    private func pushUndo(_ p: Planner) {
        undoStack.append(p)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    var canUndo: Bool { !undoStack.isEmpty }

    func undo() {
        guard let prev = undoStack.popLast() else { NSSound.beep(); return }
        redoStack.append(planner)
        write(prev)
    }

    func redo() {
        guard let next = redoStack.popLast() else { NSSound.beep(); return }
        undoStack.append(planner)
        write(next)
    }

    private func write(_ p: Planner) {
        do {
            try file.mutate { $0 = p }
            planner = p
            lastSeenModification = file.modificationDate
        } catch { lastError = error.localizedDescription }
    }

    // MARK: Watching (agents write the same file)

    private func startWatching() {
        // Poll the modification date: survives atomic replace (which breaks a single vnode watch).
        // The same tick notices the clock crossing the reset hour.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadFromDisk(external: true); self?.refreshToday() }
        }
    }

    func reloadFromDisk(external: Bool) {
        let mod = file.modificationDate
        guard mod != lastSeenModification else { return }
        lastSeenModification = mod
        guard let fresh = try? file.load(), fresh != planner else { return }
        // An agent's change is undoable with ⌘Z.
        if external { pushUndo(planner) }
        planner = fresh
        NotificationCenter.default.post(name: .plannerChangedExternally, object: nil)
    }
}

extension Notification.Name {
    static let plannerChangedExternally = Notification.Name("PerchPlannerChangedExternally")
    static let perchOpenWorkspace = Notification.Name("PerchOpenWorkspace")
}
