import Foundation
#if canImport(Glibc)
    import Glibc
#else
    import Darwin
#endif

public struct ReminderLink: Codable, Equatable, Sendable {
    public let owner: ReminderOwner
    public var remoteID: String?
    public var local: ReminderFields?
    public var remote: ReminderFields?
    public var revision: String?
    public var retired: Bool = false
    public init(owner: ReminderOwner) { self.owner = owner }
}

/// Sync metadata is deliberately outside the planner document and its undo history.
public struct ReminderLedger: Codable, Equatable, Sendable {
    public var version = 1
    public var installation = UUID()
    public var enabled = false
    public var calendarID: String?
    public var links: [UUID: ReminderLink] = [:]
    public init() {}
}

@MainActor
public protocol ReminderLedgerStorage: AnyObject {
    func lock() throws
    func unlock()
    func load() throws -> ReminderLedger
    func save(_ ledger: ReminderLedger) throws
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
    public func load() throws -> ReminderLedger {
        guard FileManager.default.fileExists(atPath: url.path) else { return ReminderLedger() }
        let ledger = try JSONDecoder().decode(ReminderLedger.self, from: Data(contentsOf: url))
        guard ledger.version == 1,
            ledger.links.allSatisfy({
                $0.key == $0.value.owner.task && $0.value.owner.installation == ledger.installation
            })
        else {
            throw ReminderSyncError.stopped(
                "Reminders metadata needs recovery. Sync is stopped; no reminders were changed.")
        }
        return ledger
    }
    public func save(_ ledger: ReminderLedger) throws {
        guard descriptor >= 0 else { throw ReminderSyncError.stopped("Reminders metadata is not locked.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(ledger).write(to: url, options: [.atomic])
    }
}
