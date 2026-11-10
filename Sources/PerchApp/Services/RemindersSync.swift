import Combine
import EventKit
import PlannerCore

// MARK: - Two-way sync with an Apple Reminders list named "Perch"

@MainActor
final class RemindersSync: ObservableObject {
    static let listName = "Perch"
    let store: PlannerStore
    private let ek = EKEventStore()
    @Published var lastError: String?
    private var syncing = false
    private var cancellable: AnyCancellable?

    init(store: PlannerStore) {
        self.store = store
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: ek, queue: .main) {
            [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        cancellable = store.$planner.debounce(for: .seconds(1.5), scheduler: RunLoop.main).sink { [weak self] _ in
            self?.sync()
        }
    }

    var hasAccess: Bool {
        let s = EKEventStore.authorizationStatus(for: .reminder)
        return s == .fullAccess
    }

    func requestAccess() async -> Bool {
        _ = try? await ek.requestFullAccessToReminders()
        return hasAccess
    }

    private func list() throws -> EKCalendar {
        if let c = ek.calendars(for: .reminder).first(where: { $0.title == Self.listName }) { return c }
        let c = EKCalendar(for: .reminder, eventStore: ek)
        c.title = Self.listName
        guard
            let source = ek.defaultCalendarForNewReminders()?.source
                ?? ek.sources.first(where: { $0.sourceType == .calDAV || $0.sourceType == .local })
        else { throw PlannerError("Perch found no Reminders account on this Mac.") }
        c.source = source
        try ek.saveCalendar(c, commit: true)
        return c
    }

    /// Open tasks from today on go to Reminders; ticking one off on the phone completes it here.
    /// Only the "Perch" list is ever touched.
    func sync() {
        guard store.prefs.remindersSync, hasAccess, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            let cal = try list()
            let pred = ek.predicateForReminders(in: [cal])
            var fetched: [EKReminder] = []
            let sem = DispatchSemaphore(value: 0)
            ek.fetchReminders(matching: pred) { r in
                fetched = r ?? []; sem.signal()
            }
            sem.wait()
            let byID = Dictionary(fetched.map { ($0.calendarItemIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
            let today = store.today
            var links: [UUID: String] = [:]
            var completedRemotely: [UUID] = []

            for t in store.planner.tasks {
                guard let d = t.day, d >= today else { continue }
                let r = t.reminderLink.flatMap { byID[$0] }
                if let r, r.isCompleted, !t.done, d == today { completedRemotely.append(t.id); continue }
                if t.done {
                    if let r, !r.isCompleted { r.isCompleted = true; try? ek.save(r, commit: false) }; continue
                }
                let rem = r ?? EKReminder(eventStore: ek)
                rem.calendar = cal
                rem.title = t.title
                rem.notes = t.notes.isEmpty ? nil : t.notes
                rem.priority = [.high: 1, .medium: 5, .low: 9, .none: 0][t.priority]!
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: d.date())
                if let at = t.remindAt {
                    comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
                    rem.alarms = store.prefs.ringOnPhone ? [EKAlarm(absoluteDate: at)] : nil
                } else {
                    rem.alarms = nil
                }
                rem.dueDateComponents = comps
                try ek.save(rem, commit: false)
                if t.reminderLink != rem.calendarItemIdentifier { links[t.id] = rem.calendarItemIdentifier }
            }
            try ek.commit()
            guard !links.isEmpty || !completedRemotely.isEmpty else { lastError = nil; return }
            store.apply { e in
                for (id, link) in links {
                    if let i = e.planner.tasks.firstIndex(where: { $0.id == id }) {
                        e.planner.tasks[i].reminderLink = link
                    }
                }
                for id in completedRemotely { _ = try? e.complete(id.uuidString) }
            }
            lastError = nil
        } catch {
            lastError = "Reminders sync failed: \(error.localizedDescription)"
        }
    }
}
