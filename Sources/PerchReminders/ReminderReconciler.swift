import Foundation
import PlannerCore

/// One-way mirroring by default; explicitly opted-in two-way reconciliation uses durable intents.
/// Unknown ownership and conflicting edits always stop instead of guessing.
@MainActor
public final class ReminderReconciler {
    private let repository: any ReminderRepository
    private let storage: any ReminderLedgerStorage
    private var running = false
    public init(repository: any ReminderRepository, storage: any ReminderLedgerStorage) {
        self.repository = repository; self.storage = storage
    }

    public func enabled() throws -> Bool {
        try storage.lock(); defer { storage.unlock() }
        return try storage.load().enabled
    }

    public func twoWayEnabled() throws -> Bool {
        try storage.lock(); defer { storage.unlock() }
        return try storage.load().twoWayEnabled
    }

    /// Call only after the user explicitly confirms experimental two-way synchronization.
    public func setTwoWayEnabled(_ enabled: Bool) throws {
        try storage.lock(); defer { storage.unlock() }
        var ledger = try storage.load()
        guard enabled || ledger.links.values.allSatisfy({ $0.pending == nil }) else {
            throw ReminderSyncError.stopped("Finish or resolve the pending two-way sync before changing modes.")
        }
        ledger.twoWayEnabled = enabled
        try storage.save(ledger)
    }

    public func disable() throws {
        try storage.lock(); defer { storage.unlock() }
        var ledger = try storage.load()
        guard ledger.enabled else { return }
        ledger.enabled = false
        try storage.save(ledger)
    }

    public func enable() throws {
        try storage.lock(); defer { storage.unlock() }
        var ledger = try storage.load()
        ledger.enabled = true
        try storage.save(ledger)
    }

    public func reconcile(
        _ planner: Planner, today: DayKey, validate: () throws -> Void = {},
        complete: (PlanTask) throws -> Void = { _ in },
        prepareImport: (PlanTask, ReminderFields?) throws -> Void = { _, _ in
            throw ReminderSyncError.stopped("Two-way sync requires a validated planner adapter.")
        },
        applyImport: (PlanTask, ReminderFields?) throws -> Void = { _, _ in
            throw ReminderSyncError.stopped("Two-way sync requires a durable planner adapter.")
        }
    ) async throws {
        guard !running else { throw ReminderSyncError.stopped("Reminders sync is already running.") }
        running = true; defer { running = false }
        try storage.lock(); defer { storage.unlock() }
        var ledger = try storage.load()
        guard ledger.enabled else {
            throw ReminderSyncError.stopped(
                "Reminders sync is paused. Turn it off and on in Settings to enable safe mirroring. Existing reminders will not be adopted or changed."
            )
        }
        try checkAccess()
        try validate()
        if ledger.twoWayEnabled {
            try await TwoWayReminderReconciler(repository: repository, storage: storage).reconcile(
                &ledger, planner: planner, today: today, validate: validate,
                prepareImport: prepareImport, applyImport: applyImport)
            return
        }
        guard ledger.links.values.allSatisfy({ $0.pending == nil }) else {
            throw ReminderSyncError.stopped("Pending two-way changes must be recovered before mirroring.")
        }
        let active = planner.tasks.filter { $0.day.map { $0 >= today } ?? false }
        // Never create a list merely to process an empty or disabled planner.
        if ledger.calendarID == nil {
            guard active.contains(where: { !$0.done }) else { return }
            try validate(); try checkAccess()
            ledger.calendarID = try repository.createCalendar()
            try storage.save(ledger)
        }
        guard let calendarID = ledger.calendarID else { return }
        let records = try await repository.fetch(calendarID: calendarID)
        try checkAccess(); try validate()
        // Do not silently resolve duplicate ownership or identifier collisions.
        guard Set(records.map(\.id)).count == records.count else {
            throw ReminderSyncError.stopped("Reminders returned duplicate identifiers. Sync is stopped.")
        }
        var byOwner: [ReminderOwner: ReminderSyncRecord] = [:]
        for record in records {
            guard record.calendarID == calendarID else {
                throw ReminderSyncError.stopped("The Reminders list changed while syncing. Retry sync.")
            }
            if let owner = record.owner, owner.installation == ledger.installation {
                guard byOwner[owner] == nil else {
                    throw ReminderSyncError.stopped(
                        "A mirrored reminder was duplicated. Resolve the duplicate before syncing.")
                }
                byOwner[owner] = record
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let activeIDs = Set(active.map(\.id))
        let taskIDs = Set(planner.tasks.map(\.id))
        for id in ledger.links.keys.sorted(by: { $0.uuidString < $1.uuidString }) where !activeIDs.contains(id) {
            guard var link = ledger.links[id] else { continue }
            let record = try await ownedRecord(link, byOwner: byOwner, byID: byID, validate: validate)
            if link.retired {
                guard record == nil else {
                    throw ReminderSyncError.stopped("A retired reminder reappeared. It was preserved; sync is stopped.")
                }
                // A suspended live task can later be deleted while outside the mirrored date range.
                if !taskIDs.contains(id), link.retirement == .outOfScope {
                    link.retirement = .deleted; link.deletedAt = Date()
                    ledger.links[id] = link; try storage.save(ledger)
                }
                continue
            }
            guard record != nil || link.remoteID == nil else {
                throw ReminderSyncError.stopped(
                    "A linked reminder disappeared before scope cleanup. It will not be recreated automatically.")
            }
            if let record {
                guard !record.unsupported, record.fields == (link.remote ?? link.local) else {
                    throw ReminderSyncError.stopped(
                        "A removed task's reminder was edited elsewhere. It was preserved; resolve the change before syncing."
                    )
                }
                try validate(); try checkAccess()
                try repository.remove(record)
            }
            link.retired = true
            link.retirement = taskIDs.contains(id) ? .outOfScope : .deleted
            if link.retirement == .outOfScope { link.remoteID = nil } else { link.deletedAt = Date() }
            link.remote = nil; link.revision = nil
            ledger.links[id] = link; try storage.save(ledger)
        }
        for task in active.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            if let link = ledger.links[task.id], link.retired,
                link.retirement != .outOfScope || link.deletedAt != nil
            {
                throw ReminderSyncError.stopped(
                    "This task's sync identity was deleted or has unknown legacy retirement metadata. Create a new task to sync it again."
                )
            }
            var desired = ReminderFields(task: task, ringOnPhone: planner.preferences.ringOnPhone)
            var link =
                ledger.links[task.id]
                ?? ReminderSyncLink(owner: ReminderOwner(installation: ledger.installation, task: task.id))
            let record = try await ownedRecord(link, byOwner: byOwner, byID: byID, validate: validate)
            if link.retired, record != nil {
                throw ReminderSyncError.stopped("A retired reminder reappeared. It was preserved; sync is stopped.")
            }
            link.retirement = nil
            if let record {
                guard !record.unsupported else {
                    throw ReminderSyncError.stopped(
                        "A mirrored reminder has unsupported fields. It was preserved; remove its recurrence or extra alarms before syncing."
                    )
                }
                if record.fields != desired {
                    let base = link.remote ?? link.local
                    if record.fields != base {
                        var completed = base
                        completed?.completed = true
                        guard !task.done, task.day == today, desired == link.local,
                            base?.completed == false, record.fields == completed
                        else {
                            throw ReminderSyncError.stopped(
                                "A reminder changed outside Perch. Remote text edits, reopening and future-day completion are not imported. Resolve the difference before syncing."
                            )
                        }
                        try validate(); try checkAccess()
                        try complete(task)
                        desired.completed = true
                        // A remote completion needs no EventKit save.
                        link.local = desired; link.remote = record.fields; link.remoteID = record.id
                        link.revision = record.revision; link.retired = false
                        if ledger.links[task.id] != link { ledger.links[task.id] = link; try storage.save(ledger) }
                        continue
                    }
                    try validate(); try checkAccess()
                    let saved = try repository.save(
                        fields: desired, owner: link.owner, calendarID: calendarID, replacing: record)
                    link.remoteID = saved.id; link.remote = saved.fields; link.revision = saved.revision
                } else {
                    link.remoteID = record.id; link.remote = record.fields; link.revision = record.revision
                }
            } else {
                guard link.remoteID == nil else {
                    throw ReminderSyncError.stopped(
                        "A mirrored reminder was deleted or moved outside Perch. It will not be recreated automatically."
                    )
                }
                // Completed tasks without a mirror do not create new reminders.
                if task.done { continue }
                // Write intent before EventKit: a crash after save is recovered by its stable ownership URL.
                link.local = desired; link.retired = false
                if ledger.links[task.id] != link { ledger.links[task.id] = link; try storage.save(ledger) }
                try validate(); try checkAccess()
                let saved = try repository.save(
                    fields: desired, owner: link.owner, calendarID: calendarID, replacing: nil)
                link.remoteID = saved.id; link.remote = saved.fields; link.revision = saved.revision
            }
            link.local = desired; link.retired = false
            if ledger.links[task.id] != link { ledger.links[task.id] = link; try storage.save(ledger) }
        }
    }

    private func checkAccess() throws {
        guard repository.hasAccess else {
            throw ReminderSyncError.stopped(
                "Reminders permission is unavailable. No further reminders were changed; grant access in System Settings and retry."
            )
        }
    }

    private func ownedRecord(
        _ link: ReminderSyncLink, byOwner: [ReminderOwner: ReminderSyncRecord], byID: [String: ReminderSyncRecord],
        validate: () throws -> Void
    ) async throws -> ReminderSyncRecord? {
        if let id = link.remoteID, let record = byID[id], record.owner != link.owner {
            throw ReminderSyncError.stopped("A reminder's ownership marker changed. It was preserved; sync is stopped.")
        }
        // Identifiers can change after an account refresh; the persisted owner token is authoritative.
        if let record = byOwner[link.owner] { return record }
        if link.local != nil || link.remoteID != nil || link.retired || link.pending != nil {
            try checkAccess(); try validate()
            if let id = link.remoteID, try repository.lookup(id: id) != nil {
                throw ReminderSyncError.stopped(
                    "A linked reminder moved outside its list. Move it back before retrying.")
            }
            guard try await repository.locate(owner: link.owner).isEmpty else {
                throw ReminderSyncError.stopped(
                    "A linked reminder is still present outside this snapshot. Retry without recreating it.")
            }
            try checkAccess(); try validate()
        }
        return nil
    }
}
