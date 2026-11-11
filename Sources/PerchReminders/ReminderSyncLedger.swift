import Foundation
#if canImport(Glibc)
    import Glibc
#else
    import Darwin
#endif

public struct ReminderSyncLink: Codable, Equatable, Sendable {
    public let owner: ReminderOwner
    public var remoteID: String?
    public var local: ReminderFields?
    public var remote: ReminderFields?
    public var revision: String?
    public var retired: Bool = false
    /// Missing on old retired links: the old format did not distinguish scope exit from deletion.
    public enum Retirement: String, Codable, Sendable { case outOfScope, deleted }
    public var retirement: Retirement?
    public var deletedAt: Date?
    public var pending: ReminderSyncIntent?
    public var cleanup: ReminderCleanupIntent?
    public init(owner: ReminderOwner) { self.owner = owner }
}

/// Sync metadata is deliberately outside the planner document and its undo history.
public struct ReminderSyncLedger: Codable, Equatable, Sendable {
    public var version = 4
    public var twoWayEnabled = false
    public var installation = UUID()
    public var enabled = false
    public var calendarID: String?
    public var links: [UUID: ReminderSyncLink] = [:]
    public init() {}
    private enum CodingKeys: String, CodingKey { case version, installation, enabled, calendarID, links, twoWayEnabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        guard (1...4).contains(version) else {
            throw ReminderSyncError.stopped("This Reminders metadata version is not supported.")
        }
        self.version = 4
        installation = try c.decode(UUID.self, forKey: .installation)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        calendarID = try c.decodeIfPresent(String.self, forKey: .calendarID)
        links = try c.decode([UUID: ReminderSyncLink].self, forKey: .links)
        if version < 3 {
            // Old formats cannot certify a scope exit. Keep their retirement opaque and fail closed
            // if that identity becomes active; dormant historical tasks do not block other syncing.
            for id in links.keys { links[id]?.retirement = nil }
        }
        guard
            links.values.allSatisfy({ link in
                if let cleanup = link.cleanup {
                    guard version >= 4, !link.retired, link.pending == nil,
                        link.retirement == nil, link.deletedAt == nil,
                        link.remoteID == cleanup.remoteID, !cleanup.remoteID.isEmpty,
                        !cleanup.revision.isEmpty, calendarID != nil
                    else { return false }
                }
                if link.retired && link.pending != nil { return false }
                switch link.retirement {
                case .outOfScope:
                    return link.retired && link.deletedAt == nil && link.remoteID == nil
                        && link.remote == nil && link.revision == nil
                case .deleted:
                    return link.retired && link.deletedAt != nil
                case nil:
                    return link.deletedAt == nil || link.retired
                }
            })
        else {
            throw ReminderSyncError.stopped("Inconsistent Reminders retirement metadata. No changes were applied.")
        }
        // Upgrading metadata never opts the user into two-way writes.
        twoWayEnabled = version >= 2 ? try c.decodeIfPresent(Bool.self, forKey: .twoWayEnabled) ?? false : false
    }
}

/// One-way removal authorization, persisted before touching the remote record. Keeping the reason
/// separate from two-way edits permits recovery without interpreting a scope exit as task deletion.
public struct ReminderCleanupIntent: Codable, Equatable, Sendable {
    public let reason: ReminderSyncLink.Retirement
    public let remoteID: String
    public let fields: ReminderFields
    public let revision: String
    public init(reason: ReminderSyncLink.Retirement, record: ReminderSyncRecord) {
        self.reason = reason; remoteID = record.id; fields = record.fields; revision = record.revision
    }
}

/// Write-ahead intent. Each side may be at its before or target value after a restart.
/// A nil target is a durable deletion, never an instruction to recreate a missing task.
public struct ReminderSyncIntent: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable { case upsert, delete }
    public let operation: Operation
    public var localBefore: ReminderFields?
    public var remoteBefore: ReminderFields?
    public var remoteRevision: String?
    public var target: ReminderFields?
    public init(
        localBefore: ReminderFields?, remoteBefore: ReminderFields?, remoteRevision: String?, target: ReminderFields?
    ) {
        operation = target == nil ? .delete : .upsert
        self.localBefore = localBefore; self.remoteBefore = remoteBefore
        self.remoteRevision = remoteRevision; self.target = target
    }
    private enum CodingKeys: String, CodingKey { case operation, localBefore, remoteBefore, remoteRevision, target }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operation = try c.decode(Operation.self, forKey: .operation)
        localBefore = try c.decodeIfPresent(ReminderFields.self, forKey: .localBefore)
        remoteBefore = try c.decodeIfPresent(ReminderFields.self, forKey: .remoteBefore)
        remoteRevision = try c.decodeIfPresent(String.self, forKey: .remoteRevision)
        target = try c.decodeIfPresent(ReminderFields.self, forKey: .target)
        guard (operation == .delete) == (target == nil),
            localBefore != nil || remoteBefore != nil,
            remoteBefore == nil || remoteRevision != nil
        else {
            throw ReminderSyncError.stopped("Incomplete Reminders recovery intent. No changes were applied.")
        }
    }
}

@MainActor
public protocol ReminderLedgerStorage: AnyObject {
    func lock() throws
    func unlock()
    func load() throws -> ReminderSyncLedger
    func save(_ ledger: ReminderSyncLedger) throws
}

/// A nonblocking process lock covers the whole reconciliation, including suspended fetches.
@MainActor
public final class ReminderLedgerFile: ReminderLedgerStorage {
    private let url: URL
    private var descriptor: Int32 = -1
    public init(url: URL) { self.url = url }
    public func lock() throws {
        guard descriptor == -1 else { throw ReminderSyncError.stopped("Reminders sync is already running.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ReminderSyncError.stopped("Cannot lock Reminders sync metadata.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw ReminderSyncError.stopped("Another Perch process is syncing Reminders. Retry shortly.")
        }
        descriptor = fd
    }
    public func unlock() {
        if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 }
    }
    public func load() throws -> ReminderSyncLedger {
        guard FileManager.default.fileExists(atPath: url.path) else { return ReminderSyncLedger() }
        let ledger = try JSONDecoder().decode(ReminderSyncLedger.self, from: Data(contentsOf: url))
        guard ledger.version == 4,
            ledger.links.allSatisfy({
                $0.key == $0.value.owner.task && $0.value.owner.installation == ledger.installation
            })
        else {
            throw ReminderSyncError.stopped(
                "Reminders metadata needs recovery. Sync is stopped; no reminders were changed.")
        }
        return ledger
    }
    public func save(_ ledger: ReminderSyncLedger) throws {
        guard descriptor >= 0 else { throw ReminderSyncError.stopped("Reminders metadata is not locked.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(ledger).write(to: url, options: [.atomic])
    }
}
