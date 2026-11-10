import Combine
import EventKit
import PlannerCore

// MARK: - Two-way sync with an Apple Reminders list named "Perch"

@MainActor
final class RemindersSync: ObservableObject {
    static let listName = "Perch"
    let store: PlannerStore
    private let source: any RemindersAccess
    @Published var lastError: String?
    private var syncing = false
    private var cancellable: AnyCancellable?

    init(store: PlannerStore, source: (any RemindersAccess)? = nil) {
        self.store = store
        self.source = source ?? SystemRemindersAccess()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) {
            [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        cancellable = store.$planner.debounce(for: .seconds(1.5), scheduler: RunLoop.main).sink { [weak self] _ in
            self?.sync()
        }
    }

    var hasAccess: Bool { source.hasAccess }

    func requestAccess() async -> Bool {
        _ = try? await source.requestAccess()
        return hasAccess
    }

    /// Open tasks from today on go to Reminders; ticking one off on the phone completes it here.
    /// Only the "Perch" list is ever touched.
    func sync() {
        guard store.prefs.remindersSync, hasAccess, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            let result = try source.synchronize(store.planner, today: store.today)
            let links = result.links, completedRemotely = result.completed
            guard !links.isEmpty || !completedRemotely.isEmpty else { lastError = nil; return }
            store.applyUntracked { commands in
                try commands.execute(.reminderLinks(links))
                for id in completedRemotely {
                    if let task = commands.planner.tasks.first(where: { $0.id == id }), task.day == commands.today,
                        !task.done
                    {
                        try commands.complete(id)
                    }
                }
            }
            lastError = nil
        } catch {
            lastError = "Reminders sync failed: \(error.localizedDescription)"
        }
    }
}
