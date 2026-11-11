import Foundation
import PlannerCore

/// Three-way, field-level reconciliation. Clocks never select a winner: simultaneous divergent
/// edits (including edit versus delete) stop. Revisions protect writes; intents recover commits.
@MainActor
struct TwoWayReminderReconciler {
    let repository: any ReminderRepository
    let storage: any ReminderLedgerStorage

    func reconcile(
        _ ledger: inout ReminderSyncLedger, planner: Planner, today: DayKey,
        validate: () throws -> Void, prepareImport: (PlanTask, ReminderFields?) throws -> Void,
        applyImport: (PlanTask, ReminderFields?) throws -> Void
    ) async throws {
        let newTasks = planner.tasks.filter { !$0.done && ($0.day.map { $0 >= today } ?? false) }
        if ledger.calendarID == nil {
            guard !newTasks.isEmpty else { return }
            try check(validate)
            ledger.calendarID = try repository.createCalendar()
            try storage.save(ledger)
        }
        guard let calendarID = ledger.calendarID else { return }
        let records = try await repository.fetch(calendarID: calendarID)
        try check(validate)
        guard Set(records.map(\.id)).count == records.count,
            records.allSatisfy({ $0.calendarID == calendarID })
        else { throw conflict("The Reminders snapshot contains conflicting identifiers or lists.") }
        var byOwner: [ReminderOwner: ReminderSyncRecord] = [:]
        for record in records where record.owner?.installation == ledger.installation {
            guard let owner = record.owner, byOwner[owner] == nil else {
                throw conflict("A linked reminder was duplicated.")
            }
            byOwner[owner] = record
        }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        guard Set(planner.tasks.map(\.id)).count == planner.tasks.count else {
            throw conflict("The planner contains duplicate task identities.")
        }
        let tasks = Dictionary(uniqueKeysWithValues: planner.tasks.map { ($0.id, $0) })
        let ids = Set(ledger.links.keys).union(newTasks.map(\.id)).sorted { $0.uuidString < $1.uuidString }
        for id in ids {
            try check(validate)
            let task = tasks[id]
            let local = task.map { ReminderFields(task: $0, ringOnPhone: planner.preferences.ringOnPhone) }
            var link =
                ledger.links[id] ?? ReminderSyncLink(owner: ReminderOwner(installation: ledger.installation, task: id))
            if let oldID = link.remoteID, let record = byID[oldID], record.owner != link.owner {
                throw conflict("A linked reminder's ownership marker changed.")
            }
            var remote = byOwner[link.owner]
            if remote == nil, let oldID = link.remoteID {
                // A scoped fetch cannot prove deletion. A reminder moved to another list stays untouched.
                try check(validate)
                if try repository.lookup(id: oldID) != nil {
                    throw conflict("A linked reminder was moved outside its list. Move it back before retrying.")
                }
                guard try await repository.locate(owner: link.owner).isEmpty else {
                    throw conflict(
                        "The linked reminder is still present in another snapshot or list. Retry without deleting it.")
                }
                try check(validate)
            }
            if link.retired {
                guard task == nil, remote == nil else {
                    throw conflict(
                        "A deleted task or reminder reappeared. Create a new task instead of reusing its deleted identity."
                    )
                }
                continue
            }
            guard remote?.unsupported != true else {
                throw conflict("A linked reminder has unsupported recurrence, alarms or other fields.")
            }
            if link.pending == nil {
                let target: ReminderFields?
                if local == nil {
                    guard remote == nil || remote?.fields == (link.remote ?? link.local) else {
                        throw conflict(
                            "The task was deleted while its reminder was edited. Both versions were preserved.")
                    }
                    target = nil
                } else if remote == nil {
                    if link.remoteID != nil {
                        guard local == link.local else {
                            throw conflict(
                                "The reminder was deleted while its task was edited. The task was preserved.")
                        }
                        target = nil
                    } else {
                        target = local
                    }
                } else if let local, let remote {
                    if let baseLocal = link.local, let baseRemote = link.remote ?? link.local {
                        target = try merge(local, remote.fields, baseLocal: baseLocal, baseRemote: baseRemote)
                    } else {
                        // Recovery of an old one-way create intent is safe only if both copies agree.
                        guard local == remote.fields else {
                            throw conflict("A new link changed before its first checkpoint.")
                        }
                        target = local
                    }
                } else {
                    target = nil
                }
                if local == target, remote?.fields == target {
                    checkpoint(&link, target: target, remote: remote)
                    if ledger.links[id] != link { ledger.links[id] = link; try storage.save(ledger) }
                    continue
                }
                if let task, local != target { try prepareImport(task, target) }
                link.pending = ReminderSyncIntent(
                    localBefore: local, remoteBefore: remote?.fields,
                    remoteRevision: remote?.revision, target: target)
                ledger.links[id] = link
                // Nothing on either side is changed unless recovery metadata is durable first.
                try storage.save(ledger)
            }
            guard let intent = link.pending else { continue }
            // Explicit manual agreement can resolve an interrupted edit, but cannot cancel a deletion
            // by silently bringing its old identity back to life.
            if local == remote?.fields, (intent.target != nil || local == nil) {
                checkpoint(&link, target: local, remote: remote)
                ledger.links[id] = link; try storage.save(ledger)
                continue
            }
            guard local == intent.localBefore || local == intent.target,
                remote?.fields == intent.remoteBefore || remote?.fields == intent.target
            else { throw conflict("A pending sync changed after interruption. Both versions were preserved.") }
            if let remote, remote.fields != intent.target,
                remote.revision != intent.remoteRevision
            {
                throw conflict("The reminder revision changed after interruption.")
            }
            if local != intent.target {
                guard let task else { throw conflict("A deleted task will not be recreated by recovery.") }
                try prepareImport(task, intent.target)
                try check(validate)
                // Imports also depend on a current remote revision, even when no remote write follows.
                if let record = remote {
                    guard try repository.lookup(id: record.id) == record else {
                        throw conflict("The reminder changed before its edit could be imported.")
                    }
                } else if let oldID = link.remoteID, try repository.lookup(id: oldID) != nil {
                    throw conflict("The reminder reappeared before its deletion could be imported.")
                }
                try check(validate)
                try applyImport(task, intent.target)
            }
            if remote?.fields != intent.target {
                try check(validate)
                if let target = intent.target {
                    remote = try repository.save(
                        fields: target, owner: link.owner, calendarID: calendarID, replacing: remote)
                    guard remote?.owner == link.owner, remote?.calendarID == calendarID,
                        remote?.fields == target, remote?.unsupported == false
                    else {
                        throw conflict("Reminders changed the saved fields. The pending sync was kept for recovery.")
                    }
                } else if let record = remote {
                    try repository.remove(record)
                    remote = nil
                }
            }
            checkpoint(&link, target: intent.target, remote: remote)
            ledger.links[id] = link
            try storage.save(ledger)
        }
    }

    private func checkpoint(_ link: inout ReminderSyncLink, target: ReminderFields?, remote: ReminderSyncRecord?) {
        link.local = target; link.remote = remote?.fields; link.revision = remote?.revision
        // Retain the last identifier on a tombstone, so reappearance cannot be adopted.
        if let remote { link.remoteID = remote.id }
        link.retired = target == nil
        if link.retired, link.deletedAt == nil { link.deletedAt = Date() }
        link.pending = nil
    }

    private func merge(
        _ local: ReminderFields, _ remote: ReminderFields, baseLocal: ReminderFields, baseRemote: ReminderFields
    ) throws -> ReminderFields {
        var result = local
        result.title = try field(local.title, remote.title, baseLocal.title, baseRemote.title)
        result.notes = try field(local.notes, remote.notes, baseLocal.notes, baseRemote.notes)
        result.priority = try field(local.priority, remote.priority, baseLocal.priority, baseRemote.priority)
        result.completed = try field(local.completed, remote.completed, baseLocal.completed, baseRemote.completed)
        // Due and alarm are one schedule, not independently mergeable values.
        let l = Schedule(due: local.due, alarm: local.alarm), r = Schedule(due: remote.due, alarm: remote.alarm)
        let bL = Schedule(due: baseLocal.due, alarm: baseLocal.alarm),
            bR = Schedule(due: baseRemote.due, alarm: baseRemote.alarm)
        let schedule = try field(l, r, bL, bR)
        result.due = schedule.due; result.alarm = schedule.alarm
        return result
    }

    private struct Schedule: Equatable { var due: DateComponents?; var alarm: Date? }
    private func field<T: Equatable>(_ local: T, _ remote: T, _ baseLocal: T, _ baseRemote: T) throws -> T {
        if local == remote { return local }
        if remote == baseRemote { return local }
        if local == baseLocal { return remote }
        throw conflict("The same field was edited in Perch and Reminders. Make both copies agree, then retry.")
    }
    private func check(_ validate: () throws -> Void) throws {
        guard repository.hasAccess else { throw conflict("Reminders permission is unavailable.") }
        try validate()
    }
    private func conflict(_ message: String) -> ReminderSyncError { .stopped(message) }
}
