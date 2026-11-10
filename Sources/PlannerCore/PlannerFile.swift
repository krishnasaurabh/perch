import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private enum PlannerDateCoding {
    // Foundation's .iso8601 strategy discards subsecond timestamps, which would recount
    // the truncated part of resumedAt at every checkpoint after a disk reload.
    static func string(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceReferenceDate
        let whole = floor(seconds)
        let base = ISO8601DateFormatter().string(from: Date(timeIntervalSinceReferenceDate: whole))
        let fraction = seconds - whole
        guard fraction > 0 else { return base }
        let suffix = String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), fraction).dropFirst()
        return String(base.dropLast()) + suffix + "Z"
    }

    static func date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        let parts = string.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return formatter.date(from: string) }
        guard let zone = parts[1].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }),
              let fraction = Double("0." + parts[1][..<zone]),
              let base = formatter.date(from: String(parts[0]) + parts[1][zone...]) else { return nil }
        return Date(timeIntervalSinceReferenceDate: base.timeIntervalSinceReferenceDate + fraction)
    }
}

/// planner.json on disk. Shared by the app and the MCP server process, so every
/// read-modify-write holds an advisory file lock and writes atomically.
public final class PlannerFile: @unchecked Sendable {
    public let url: URL
    let lockURL: URL
    /// The five most recent pre-save revisions, newest first via `backupURLs()`.
    public static let backupLimit = 5
    public var backupDirectory: URL { url.appendingPathExtension("backups") }

    // Fault injection stays internal; production always uses atomic Foundation writes.
    struct IO {
        var read: (URL) throws -> Data = { try Data(contentsOf: $0) }
        var write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
        var copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
        var remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    }
    private let io: IO

    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["PERCH_DATA"] { return URL(fileURLWithPath: override) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share")
        return base.appendingPathComponent("Perch/planner.json")
    }

    public convenience init(url: URL = PlannerFile.defaultURL) {
        self.init(url: url, io: IO())
    }

    init(url: URL, io: IO) {
        self.url = url
        self.io = io
        lockURL = url.appendingPathExtension("lock")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(PlannerDateCoding.string(date))
        }
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let string = try c.decode(String.self)
            guard let date = PlannerDateCoding.date(string) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid ISO 8601 date.")
            }
            return date
        }
        return d
    }

    // Planner's migration decoder intentionally defaults missing fields, but also
    // defaults failed collection decodes. Never promote such a lossy read to a backup.
    private struct ValidatedPlanner: Decodable {
        let planner: Planner
        enum CodingKeys: String, CodingKey {
            case version, tasks, projects, notes, focusSegments, focus, dismissedOverdue
            case repeatOccurrences, completedCalendarEventIDs, completedCalendarEventDays, preferences
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            _ = try c.decodeIfPresent(Int.self, forKey: .version)
            _ = try c.decodeIfPresent([PlanTask].self, forKey: .tasks)
            _ = try c.decodeIfPresent([TaskProject].self, forKey: .projects)
            _ = try c.decodeIfPresent([QuickNote].self, forKey: .notes)
            _ = try c.decodeIfPresent([FocusSegment].self, forKey: .focusSegments)
            _ = try c.decodeIfPresent(FocusSession.self, forKey: .focus)
            _ = try c.decodeIfPresent([UUID].self, forKey: .dismissedOverdue)
            _ = try c.decodeIfPresent([RepeatOccurrence].self, forKey: .repeatOccurrences)
            _ = try c.decodeIfPresent(Set<String>.self, forKey: .completedCalendarEventIDs)
            _ = try c.decodeIfPresent([String: DayKey].self, forKey: .completedCalendarEventDays)
            _ = try c.decodeIfPresent(Preferences.self, forKey: .preferences)
            planner = try Planner(from: decoder)
        }
    }

    private static func decode(_ data: Data) throws -> Planner {
        try decoder.decode(ValidatedPlanner.self, from: data).planner
    }

    private func readIfPresent(_ target: URL) throws -> Data? {
        do { return try io.read(target) }
        catch {
            let e = error as NSError
            if (e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError)
                || (e.domain == NSPOSIXErrorDomain && e.code == Int(ENOENT)) { return nil }
            throw error
        }
    }

    private func preserveCorruptCurrent() throws -> URL {
        let copy = url.deletingPathExtension().appendingPathExtension("corrupt-\(UUID().uuidString).json")
        do { try io.copy(url, copy) }
        catch {
            throw PlannerError("Unable to preserve corrupt planner data: \(error.localizedDescription). The original was not changed.")
        }
        return copy
    }

    /// Missing data starts empty; unreadable or corrupt data throws without replacement.
    public func load() throws -> Planner { try withLock { try loadLocked() } }

    private func loadLocked() throws -> Planner {
        guard let data = try readIfPresent(url) else { return Planner() }
        do { return try Self.decode(data) }
        catch {
            let copy = try preserveCorruptCurrent()
            throw PlannerError("Unable to load planner data. A recovery copy is saved at \(copy.path)")
        }
    }

    /// A save fails closed if the previous revision cannot be validated and backed up.
    public func save(_ planner: Planner) throws { try withLock { try saveLocked(planner) } }

    private func saveLocked(_ planner: Planner) throws {
        let data = try Self.encoder.encode(planner)
        // Reject non-finite dates or other values that cannot survive decoding.
        _ = try Self.decode(data)
        if let current = try readIfPresent(url) {
            do { _ = try Self.decode(current) }
            catch { throw PlannerError("Planner data is corrupt. Restore a backup before saving; the original was not changed.") }
            if current == data { return }
            try backUpLocked(current)
        }
        try io.write(data, url)
    }

    /// Immutable raw-byte snapshots, newest first. Unrelated files are never pruned.
    public func backupURLs() throws -> [URL] { try withLock { try backupURLsLocked() } }

    private func backupURLsLocked() throws -> [URL] {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
        } catch {
            let e = error as NSError
            if e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError { return [] }
            throw error
        }
        return entries.filter { entry in
            let name = entry.deletingPathExtension().lastPathComponent
            return entry.pathExtension == "json" && name.hasPrefix("backup-")
                && name.count == 27 && name.dropFirst(7).allSatisfy(\.isNumber)
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func backUpLocked(_ data: Data) throws {
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let previous = try backupURLsLocked()
        // Retrying a failed current-file replacement must not evict history with duplicates.
        if let newest = previous.first, (try? io.read(newest)) == data {
            try pruneLocked(Array(previous.dropFirst(Self.backupLimit)))
            return
        }
        let number = previous.first.flatMap { UInt64($0.deletingPathExtension().lastPathComponent.dropFirst(7)) } ?? 0
        guard number < UInt64.max else { throw PlannerError("Planner backup sequence is full; the original was not changed.") }
        let name = "backup-" + String(repeating: "0", count: 20 - String(number + 1).count) + String(number + 1) + ".json"
        let backup = backupDirectory.appendingPathComponent(name)
        do {
            try io.write(data, backup)
            // Verify the actual snapshot, not only the source buffer or a successful write call.
            let copied = try io.read(backup)
            guard copied == data else { throw PlannerError("Planner backup verification failed.") }
            _ = try Self.decode(copied)
        } catch {
            try? io.remove(backup)
            throw PlannerError("Planner backup failed: \(error.localizedDescription). The original was not changed.")
        }
        try pruneLocked(Array(previous.dropFirst(Self.backupLimit - 1)))
    }

    private func pruneLocked(_ stale: [URL]) throws {
        do {
            for backup in stale { try io.remove(backup) }
        } catch {
            // Keep the verified copy on disk if pruning fails, and stop the save.
            // A retry must finish pruning before any further current-file replacement.
            throw PlannerError("Planner backup retention failed: \(error.localizedDescription). The original was not changed.")
        }
    }

    /// Explicit recovery only: choose the newest readable, decodable backup. Never
    /// silently fall back to empty data or overwrite an unreadable current file.
    @discardableResult
    public func restoreLatestBackup() throws -> Planner {
        try withLock {
            var candidate: (Data, Planner)?
            for backup in try backupURLsLocked() {
                if let data = try? io.read(backup), let planner = try? Self.decode(data) {
                    candidate = (data, planner)
                    break
                }
            }
            guard let (data, planner) = candidate else { throw PlannerError("No readable, valid planner backup is available.") }
            if let current = try readIfPresent(url) {
                if current == data { return planner }
                if (try? Self.decode(current)) != nil { try backUpLocked(current) }
                else { _ = try preserveCorruptCurrent() }
            }
            try io.write(data, url)
            return planner
        }
    }

    /// Exclusive read-modify-write across processes. Internal helpers avoid nested locks.
    @discardableResult
    public func mutate<T>(_ body: (inout Planner) throws -> T) throws -> T {
        try withLock {
            var p = try loadLocked()
            let before = p
            let result = try body(&p)
            if p != before { try saveLocked(p) }
            return result
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw PlannerError("Planner storage lock could not be opened.") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw PlannerError("Planner storage lock could not be acquired.") }
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    public var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    /// JSON export for "Export planner data".
    public func export(to dest: URL) throws {
        try withLock {
            let planner = try loadLocked()
            if dest.standardizedFileURL == url.standardizedFileURL {
                try saveLocked(planner)
            } else {
                try Self.encoder.encode(planner).write(to: dest, options: .atomic)
            }
        }
    }
}
