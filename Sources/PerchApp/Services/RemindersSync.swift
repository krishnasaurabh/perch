import Combine
import EventKit
import PerchReminders
import PlannerCore

@MainActor
final class RemindersSync: ObservableObject {
    let store: PlannerStore
    private let source: any RemindersAccess
    private let reconciler: ReminderReconciler
    private let scheduler: any AppScheduling
    @Published private(set) var lastError: RemindersSyncFailure?
    @Published private(set) var twoWayEnabled = false
    private var cancellable: AnyCancellable?
    private var dayCancellable: AnyCancellable?
    @MainActor
    private final class LifetimeState {
        var observer: NSObjectProtocol?
        var scheduled: (any AppScheduledAction)?
    }
    private let lifetimeState = MainActorLifetime(LifetimeState()) { state in
        if let observer = state.observer { NotificationCenter.default.removeObserver(observer) }
        state.scheduled?.cancel()
    }
    private var observer: NSObjectProtocol? {
        get { lifetimeState.state.observer }
        set { lifetimeState.state.observer = newValue }
    }
    private var scheduled: (any AppScheduledAction)? {
        get { lifetimeState.state.scheduled }
        set { lifetimeState.state.scheduled = newValue }
    }
    private var running = false
    private var pending = false
    private var applyingCompletion = false
    private var pausedForHistory = false
    private var sawRedo = false
    private var generation: UInt64 = 0
    private var input: Input
    private var retryCount = 0

    private struct Input: Equatable {
        struct TaskInput: Equatable {
            var id: UUID
            var day: DayKey?
            var fields: ReminderFields
        }
        var tasks: [TaskInput]
        var enabled: Bool
        init(_ planner: Planner) {
            enabled = planner.preferences.remindersSync
            tasks = planner.tasks.map {
                TaskInput(
                    id: $0.id, day: $0.day,
                    fields: ReminderFields(task: $0, ringOnPhone: planner.preferences.ringOnPhone))
            }.sorted { $0.id.uuidString < $1.id.uuidString }
        }
    }

    init(
        store: PlannerStore, source: (any RemindersAccess)? = nil,
        storage: (any ReminderLedgerStorage)? = nil, scheduler: any AppScheduling = MainQueueScheduler(),
        observing: Bool = true
    ) {
        self.store = store
        let source = source ?? SystemRemindersAccess()
        self.source = source
        self.reconciler = ReminderReconciler(
            repository: source,
            storage: storage ?? ReminderLedgerFile(url: store.file.url.appendingPathExtension("reminders.json")))
        self.scheduler = scheduler
        self.input = Input(store.planner)
        do { twoWayEnabled = try reconciler.twoWayEnabled() } catch { lastError = .access(error.localizedDescription) }
        sawRedo = store.canRedo
        pausedForHistory = sawRedo
        if store.prefs.remindersSync {
            do {
                if try !reconciler.enabled() { lastError = .consentRequired }
            } catch { lastError = .access(error.localizedDescription) }
        }
        if observing {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main)
            { [weak self] _ in
                Task { @MainActor in self?.schedule() }
            }
            // Observe before debounce so Undo cancels queued work immediately, not 1.5 seconds later.
            cancellable = store.$planner.sink { [weak self] planner in self?.changed(planner) }
            dayCancellable = store.$today.dropFirst().sink { [weak self] _ in
                guard let self else { return }
                self.generation &+= 1
                self.schedule()
            }
            schedule()
        }
    }

    var hasAccess: Bool { source.hasAccess }

    func requestAccess() async -> Bool {
        do {
            try await source.requestAccess()
            guard hasAccess else { throw ReminderSyncError.stopped("Reminders permission is unavailable.") }
            try reconciler.enable()
            pausedForHistory = false; sawRedo = false; retryCount = 0; lastError = nil
            return true
        } catch { lastError = .access(error.localizedDescription); return false }
    }

    /// Enabling is only called from the explicit destructive-sync confirmation in Settings.
    func setTwoWayEnabled(_ enabled: Bool) {
        do {
            guard !running else { throw ReminderSyncError.stopped("Wait for the current sync to finish.") }
            guard !enabled || (store.prefs.remindersSync && hasAccess) else {
                throw ReminderSyncError.stopped("Enable Reminders mirroring and grant permission first.")
            }
            try reconciler.setTwoWayEnabled(enabled)
            twoWayEnabled = enabled
            lastError = nil
            generation &+= 1
            sync()
        } catch { lastError = .sync(error.localizedDescription) }
    }

    func sync() { schedule(after: 0) }

    private func changed(_ planner: Planner) {
        let next = Input(planner)
        if applyingCompletion { input = next; return }
        let hasRedo = store.canRedo
        if hasRedo || sawRedo {
            // Without changing the store's mutation contract, conservatively pause both history traversal
            // and the first edit that clears Redo. Never infer that a prior snapshot is a new user edit.
            sawRedo = hasRedo
            pausedForHistory = true; generation &+= 1
            scheduled?.cancel(); scheduled = nil; pending = false
            if planner.preferences.remindersSync { lastError = .historyPaused }
            try? reconciler.disable()  // A suspended pass persists this again after releasing its lock.
            input = next
            return
        }
        sawRedo = hasRedo
        guard next != input else { return }
        input = next; generation &+= 1; retryCount = 0
        schedule()
    }

    private func schedule(after delay: TimeInterval = 1.5) {
        // Published values arrive in willSet, before store.prefs reflects the new toggle.
        guard input.enabled, !pausedForHistory else { return }
        if running { pending = true; return }
        scheduled?.cancel()
        scheduled = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.scheduled = nil
            Task { @MainActor in await self.reconcileNow() }
        }
    }

    /// Also used by deterministic tests; callers do not need to sleep through the debounce.
    func reconcileNow() async {
        guard store.prefs.remindersSync, !pausedForHistory else { return }
        if running { pending = true; return }
        scheduled?.cancel(); scheduled = nil; running = true; pending = false
        let revision = generation
        let day = store.today
        do {
            // The shared file is authoritative, not a possibly stale published snapshot.
            var baseline = try store.file.load()
            guard Input(baseline) == Input(store.planner) else {
                store.reloadFromDisk(external: true)
                throw ReminderSyncError.stopped(
                    "Planner changed elsewhere. Retry Reminders sync with the latest version.")
            }
            try await reconciler.reconcile(
                baseline, today: day,
                validate: {
                    guard !self.pausedForHistory, self.generation == revision, self.store.today == day,
                        Input(try self.store.file.load()) == Input(baseline)
                    else {
                        throw ReminderSyncError.stopped(
                            "Planner changed during Reminders sync. No further reminders were changed.")
                    }
                },
                complete: { expected in
                    self.applyingCompletion = true
                    defer { self.applyingCompletion = false }
                    let applied: Bool? = self.store.performMutation(origin: .background) { commands in
                        guard Input(commands.planner) == Input(baseline) else {
                            throw ReminderSyncError.stopped("Planner changed before remote completion could be saved.")
                        }
                        let current = try commands.task(expected.id)
                        guard current.day == expected.day, current.day == commands.today,
                            ReminderFields(task: current, ringOnPhone: commands.planner.preferences.ringOnPhone)
                                == ReminderFields(task: expected, ringOnPhone: baseline.preferences.ringOnPhone)
                        else {
                            throw ReminderSyncError.stopped(
                                "Task changed during Reminders sync; remote completion was not applied.")
                        }
                        try commands.complete(expected.id)
                        return true
                    }
                    guard applied == true else {
                        throw ReminderSyncError.stopped(
                            self.store.lastError?.message ?? "Remote completion could not be saved. Retry sync.")
                    }
                    baseline = self.store.planner
                    self.pending = true
                },
                prepareImport: { expected, fields in
                    _ = try ReminderTaskImport.actions(
                        task: expected, fields: fields, planner: baseline,
                        now: self.store.engine.now(), calendar: self.store.engine.calendar)
                },
                applyImport: { expected, fields in
                    self.applyingCompletion = true
                    defer { self.applyingCompletion = false }
                    let applied: Bool? = self.store.performMutation(origin: .background) { commands in
                        guard Input(commands.planner) == Input(baseline),
                            try commands.task(expected.id) == expected
                        else {
                            throw ReminderSyncError.stopped("Planner changed before the remote edit could be saved.")
                        }
                        let actions = try ReminderTaskImport.actions(
                            task: expected, fields: fields, planner: commands.planner,
                            now: commands.read.now(), calendar: commands.read.calendar)
                        for action in actions { try commands.execute(action) }
                        return true
                    }
                    guard applied == true else {
                        throw ReminderSyncError.stopped(
                            self.store.lastError?.message ?? "The remote edit could not be saved.")
                    }
                    baseline = self.store.planner
                    self.pending = true
                })
            retryCount = 0; lastError = nil
        } catch {
            lastError = pausedForHistory ? .historyPaused : .sync(error.localizedDescription)
            // One bounded retry handles temporary read/commit failures; persistent conflicts stay visible.
            if !pausedForHistory, hasAccess, retryCount == 0 { retryCount += 1; pending = true }
        }
        running = false
        if pausedForHistory {
            do { try reconciler.disable() } catch { lastError = .disableAfterHistory(error.localizedDescription) }
        } else if pending {
            pending = false; schedule(after: 2)
        }
    }
}
