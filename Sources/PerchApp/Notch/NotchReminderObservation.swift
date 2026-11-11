import Combine
import Foundation
import PerchUI

/// Projects committed reminder accounting into the notch without extending the
/// transient timeline or requesting notifications. No new polling timer is needed.
@MainActor
final class NotchReminderObservation {
    private var subscription: AnyCancellable?

    init(
        store: PlannerStore, reminders: ReminderService, model: NotchModel,
        now: @escaping () -> Date = Date.init
    ) {
        let edits = store.$planner.map { NotchActivityTimeline.triggers(planner: $0) }
            .removeDuplicates().map { _ in () }
        // The owner publishes lastError on every reconciliation outcome, including
        // nil on success, after committing records. Hop past @Published's willSet.
        let outcomes = reminders.$lastError.map { _ in () }
        // Once the visible occurrence is dismissed, select another current miss
        // immediately. An unchanged nil projection emits nothing, so this settles.
        let dismissals = model.$missedReminder.filter { $0 == nil }.map { _ in () }
        subscription = edits.merge(with: outcomes).merge(with: dismissals).receive(on: RunLoop.main)
            .sink { [weak store, weak reminders, weak model] in
                guard let store, let reminders, let model else { return }
                model.refreshMissedReminder(planner: store.planner, records: reminders.records, now: now())
            }
    }
}
