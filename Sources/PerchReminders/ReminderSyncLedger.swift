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
    public var deletedAt: Date?
    public var pending: ReminderSyncIntent?
    public init(owner: ReminderOwner) { self.owner = owner }
}

/// Sync metadata is deliberately outside the planner document and its undo history.
public struct ReminderSyncLedger: Codable, Equatable, Sendable {
    public var version = 2
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
        guard version == 1 || version == 2 else {
            throw ReminderSyncError.stopped("This Reminders metadata version is not supported.")
        }
        self.version = 2
        installation = try c.decode(UUID.self, forKey: .installation)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        calendarID = try c.decodeIfPresent(String.self, forKey: .calendarID)
        links = try c.decode([UUID: ReminderSyncLink].self, forKey: .links)
        // Upgrading metadata never opts the user into two-way writes.
        twoWayEnabled = version == 2 ? try c.decodeIfPresent(Bool.self, forKey: .twoWayEnabled) ?? false : false
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
        guard ledger.version == 2,
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
