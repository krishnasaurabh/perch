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
            let base = formatter.date(from: String(parts[0]) + parts[1][zone...])
        else { return nil }
        return Date(timeIntervalSinceReferenceDate: base.timeIntervalSinceReferenceDate + fraction)
    }
}

/// A record rejected during recovery. `path` addresses the unchanged original
/// JSON, including the array index before any invalid records were removed.
public struct PlannerRecoveryIssue: Codable, Equatable, Sendable {
    public let path: String
    public let reason: String
}

/// A storage failure that callers can distinguish from a recoverable record
/// error and an unsupported schema without parsing localized message text.
public enum PlannerDataError: Error, LocalizedError, CustomStringConvertible {
    case unreadable(url: URL, reason: String)
    case corrupt(url: URL, quarantineURL: URL?, reason: String)

    public var description: String {
        switch self {
        case let .unreadable(url, reason):
            return "Unable to read planner data at \(url.path): \(reason). "
                + "The original was not changed; check file access before retrying. No empty or reduced planner was saved."
        case let .corrupt(url, quarantineURL, reason):
            let copy = quarantineURL.map { " An exact recovery copy is saved at \($0.path)." } ?? ""
            return "Unable to load planner data at \(url.path): \(reason). The original is unchanged."
                + copy + " No reduced planner was loaded or saved over the original. "
                + "Quit Perch and repair the file or explicitly restore a known-good backup before saving."
        }
    }
    public var errorDescription: String? { description }
}

/// Normal load never returns a reduced document as if it were complete. A caller
/// may display this draft read-only; save/mutate still reject the original.
public struct PlannerRecoveryError: Error, LocalizedError, CustomStringConvertible {
    public let recoveredPlanner: Planner
    public let issues: [PlannerRecoveryIssue]
    /// Successfully decoded entries in persisted collections, before set deduplication.
    /// Singleton fields such as preferences and focus are not records.
    public let keptCount: Int
    /// Rejected collection entries, including a whole task with an invalid nested value.
    public let quarantinedCount: Int
    /// Malformed whole collections or singleton fields, counted separately from records.
    public let quarantinedFieldCount: Int
    /// Exact copy of the complete original, not only its rejected records.
    public let originalURL: URL
    public var quarantineURL: URL { originalURL }
    public let recoveredURL: URL
    public let issuesURL: URL
    public var description: String {
        "Planner data needs recovery. Kept \(keptCount) valid record(s) in a read-only draft. "
            + "Quarantined \(quarantinedCount) invalid record(s) and \(quarantinedFieldCount) invalid field(s). "
            + "Valid records are available read-only; changes cannot be saved. "
            + "The original planner is unchanged. An exact copy, including malformed records, is at \(quarantineURL.path). "
            + "A separate valid-record draft is at \(recoveredURL.path); rejected locations are listed at \(issuesURL.path). "
            + "Quit Perch and repair the original using those files, or explicitly restore a known-good backup. "
            + "Do not replace the original with the draft unless you accept omitting the rejected records."
    }
    public var errorDescription: String? { description }
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
    private let preferences: any PlannerPreferencesAdapter
    /// Immutable, byte-for-byte inputs to each migration, outside rolling retention.
    public var migrationDirectory: URL { url.appendingPathExtension("migrations") }

    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["PERCH_DATA"] { return URL(fileURLWithPath: override) }
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share")
        return base.appendingPathComponent("Perch/planner.json")
    }

    public convenience init(url: URL = PlannerFile.defaultURL, preferences: (any PlannerPreferencesAdapter)? = nil) {
        self.init(url: url, io: IO(), preferences: preferences)
    }

    init(url: URL, io: IO, preferences: (any PlannerPreferencesAdapter)? = nil) {
        self.url = url
        self.io = io
        self.preferences = preferences ?? Self.preferencesAdapter(for: url)
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

    /// The shared persisted-date decoder, also used by external adapters.
    public static var decoder: JSONDecoder {
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

    private struct SchemaVersion: Decodable { var version: Int? }

    /// Decode a disk document or a legacy export without touching storage or device preferences.
    public static func decodeDocument(_ data: Data) throws -> Planner {
        try decoder.decode(PlannerDiskDocument.self, from: data).planner
    }

    private static func decode(_ data: Data) throws -> Planner { try decodeDocument(data) }

    private static func preferencesAdapter(for url: URL) -> any PlannerPreferencesAdapter {
        if ProcessInfo.processInfo.environment["PERCH_DATA"] == nil, url == Self.defaultURL {
            return UserDefaultsPlannerPreferences()
        }
        // Explicit/synthetic data files never read or write the user's live preferences.
        let key = url.standardizedFileURL.path.utf8.reduce(UInt64(0xcbf29ce484222325)) {
            ($0 ^ UInt64($1)) &* 0x100000001b3
        }
        return UserDefaultsPlannerPreferences(defaults: UserDefaults(suiteName: "perch.isolated.\(key)")!)
    }

    private func applyingPreferences(to source: Planner) throws -> Planner {
        var planner = source
        try preferences.load()?.apply(to: &planner.preferences)
        return planner
    }

    /// Recovery is a separate path, never the decoder used to validate a save.
    /// The quarantine retains the WHOLE original byte stream, so even unknown
    /// fields, JSON number spellings and malformed nested records remain intact.
    private struct RecoveryDraft: Decodable {
        var planner = Planner()
        var issues: [PlannerRecoveryIssue] = []
        var keptCount = 0
        var quarantinedCount = 0
        var quarantinedFieldCount = 0
        enum Keys: String, CodingKey {
            case version, tasks, taskOrder, projects, notes, focusSegments, focusHistory, focusLog, focus,
                dismissedOverdue
            case repeatOccurrences, completedCalendarEventIDs, completedCalendarEventDays, preferences
        }
        private struct StringKey: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            // A malformed version cannot be inferred. Unsupported versions never
            // enter recovery: their data may be valid in another schema.
            planner.version = try c.decodeMissing(Int.self, forKey: .version, default: Planner.currentVersion)
            guard (1...PlannerDiskDocument.currentVersion).contains(planner.version) else {
                throw PlannerSchemaError(version: planner.version)
            }
            planner.version = Planner.currentVersion
            planner.tasks = records(PlanTask.self, in: c, key: .tasks)
            planner.projects = records(TaskProject.self, in: c, key: .projects)
            planner.notes = records(QuickNote.self, in: c, key: .notes)
            planner.focusSegments = records(PackedFocusHistory.self, in: c, key: .focusHistory)
                .flatMap(\.indexedSegments).sorted { $0.0 < $1.0 }.map { $0.1 }
            planner.focusSegments += records(FocusSegment.self, in: c, key: .focusSegments)
            planner.focusSegments += records(FocusSegment.self, in: c, key: .focusLog)
            // Order IDs are an index over tasks, not additional recovered user records.
            let order = value([UUID].self, in: c, key: .taskOrder, default: [])
            let ranks = Dictionary(
                order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
            planner.tasks = planner.tasks.enumerated().sorted {
                (ranks[$0.element.id] ?? order.count + $0.offset) < (ranks[$1.element.id] ?? order.count + $1.offset)
            }.map(\.element)
            planner.repeatOccurrences = records(RepeatOccurrence.self, in: c, key: .repeatOccurrences)
            planner.dismissedOverdue = records(UUID.self, in: c, key: .dismissedOverdue)
            planner.completedCalendarEventIDs = Set(records(String.self, in: c, key: .completedCalendarEventIDs))
            planner.focus = value(FocusSession?.self, in: c, key: .focus, default: nil)
            planner.preferences = value(Preferences.self, in: c, key: .preferences, default: Preferences())
            if c.contains(.completedCalendarEventDays) {
                do {
                    let entries = try c.nestedContainer(keyedBy: StringKey.self, forKey: .completedCalendarEventDays)
                    for key in entries.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
                        do {
                            planner.completedCalendarEventDays[key.stringValue] = try entries.decode(
                                DayKey.self, forKey: key)
                            keptCount += 1
                        } catch {
                            record(error, fallback: "completedCalendarEventDays.\(key.stringValue)", isRecord: true)
                        }
                    }
                } catch { record(error, fallback: Keys.completedCalendarEventDays.rawValue) }
            }
        }

        private mutating func value<T: Decodable>(
            _ type: T.Type, in c: KeyedDecodingContainer<Keys>, key: Keys, default fallback: T
        ) -> T {
            guard c.contains(key) else { return fallback }
            do { return try c.decode(type, forKey: key) } catch {
                record(error, fallback: key.rawValue); return fallback
            }
        }

        private mutating func records<T: Decodable>(_ type: T.Type, in c: KeyedDecodingContainer<Keys>, key: Keys)
            -> [T]
        {
            guard c.contains(key) else { return [] }
            var result: [T] = []
            do {
                var list = try c.nestedUnkeyedContainer(forKey: key)
                while !list.isAtEnd {
                    let index = list.currentIndex
                    // Advance the outer container before decoding a record. A bad
                    // nested value cannot stall recovery or consume its neighbor.
                    let element = try list.superDecoder()
                    do {
                        result.append(try T(from: element))
                        keptCount += 1
                    } catch { record(error, fallback: "\(key.rawValue)[\(index)]", isRecord: true) }
                }
            } catch { record(error, fallback: key.rawValue) }
            return result
        }

        private mutating func record(_ error: Error, fallback: String, isRecord: Bool = false) {
            if isRecord { quarantinedCount += 1 } else { quarantinedFieldCount += 1 }
            let path: [CodingKey]
            let reason: String
            switch error {
            case DecodingError.keyNotFound(let key, let context):
                path = context.codingPath + [key]; reason = "Required field is missing."
            case DecodingError.typeMismatch(_, let context):
                path = context.codingPath; reason = "Value has the wrong type."
            case DecodingError.valueNotFound(_, let context):
                path = context.codingPath; reason = "Required value is null."
            case DecodingError.dataCorrupted(let context):
                path = context.codingPath; reason = "Value is invalid or unrecognized."
            default:
                path = []; reason = "Record could not be decoded."
            }
            var location = ""
            for key in path {
                if let index = key.intValue {
                    location += "[\(index)]"
                } else {
                    location += (location.isEmpty ? "" : ".") + key.stringValue
                }
            }
            issues.append(PlannerRecoveryIssue(path: location.isEmpty ? fallback : location, reason: reason))
        }
    }

    private func readIfPresent(_ target: URL) throws -> Data? {
        do { return try io.read(target) } catch {
            let e = error as NSError
            if (e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError)
                || (e.domain == NSPOSIXErrorDomain && e.code == Int(ENOENT))
            {
                return nil
            }
            throw PlannerDataError.unreadable(url: target, reason: error.localizedDescription)
        }
    }

    private func preserveCorruptCurrent(_ data: Data) throws -> URL {
        // Identical repeated reloads reuse their quarantine instead of producing
        // an unbounded set of copies. Never prune a user's recovery material.
        let prefix = url.deletingPathExtension().lastPathComponent + ".corrupt-"
        let entries = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent().resolvingSymlinksInPath(), includingPropertiesForKeys: nil)
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where entry.lastPathComponent.hasPrefix(prefix) && !entry.lastPathComponent.contains(".recovered.")
            && !entry.lastPathComponent.contains(".issues.")
        {
            if (try? io.read(entry)) == data {
                // Directory enumeration may resolve a symlinked parent differently
                // from the configured data URL. Keep recovery paths stable across loads.
                return url.deletingLastPathComponent().appendingPathComponent(entry.lastPathComponent)
            }
        }
        let copy = url.deletingPathExtension().appendingPathExtension("corrupt-\(UUID().uuidString).json")
        do {
            try io.copy(url, copy)
            guard try io.read(copy) == data else { throw PlannerError("Recovery copy verification failed.") }
        } catch {
            throw PlannerError(
                "Unable to preserve corrupt planner data: \(error.localizedDescription). The original was not changed.")
        }
        return copy
    }

    /// Missing data starts empty; a recoverable error carries valid records for
    /// read-only display. No normal load ever returns a silently reduced list.
    public func load() throws -> Planner { try withLock { try applyingPreferences(to: loadLocked()) } }

    /// Atomic replacement makes this a consistent read without lock/recovery side effects.
    public func snapshot() throws -> Planner {
        guard let data = try readIfPresent(url) else { return try applyingPreferences(to: Planner()) }
        let decoded: Planner
        do { decoded = try Self.decode(data) } catch let error as PlannerSchemaError { throw error } catch {
            throw PlannerError("Unable to load planner data.")
        }
        return try applyingPreferences(to: decoded)
    }

    private func loadLocked() throws -> Planner {
        guard let data = try readIfPresent(url) else { return Planner() }
        do { return try Self.decode(data) } catch let error as PlannerSchemaError { throw error } catch {
            let copy = try preserveCorruptCurrent(data)
            guard let draft = try? Self.decoder.decode(RecoveryDraft.self, from: data), !draft.issues.isEmpty else {
                throw PlannerDataError.corrupt(
                    url: url, quarantineURL: copy,
                    reason: "The document could not be decoded into a valid-record draft")
            }
            let recovered = copy.deletingPathExtension().appendingPathExtension("recovered.json")
            let issues = copy.deletingPathExtension().appendingPathExtension("issues.json")
            do {
                let encoded = try Self.encoder.encode(draft.planner)
                _ = try Self.decode(encoded)
                try writeRecoveryFile(encoded, to: recovered)
                try writeRecoveryFile(Self.encoder.encode(draft.issues), to: issues)
            } catch {
                throw PlannerDataError.corrupt(
                    url: url, quarantineURL: copy,
                    reason: "Recovery draft could not be saved: \(error.localizedDescription)")
            }
            throw PlannerRecoveryError(
                recoveredPlanner: draft.planner, issues: draft.issues,
                keptCount: draft.keptCount, quarantinedCount: draft.quarantinedCount,
                quarantinedFieldCount: draft.quarantinedFieldCount,
                originalURL: copy, recoveredURL: recovered, issuesURL: issues)
        }
    }

    private func writeRecoveryFile(_ data: Data, to target: URL) throws {
        if (try? io.read(target)) == data { return }
        try io.write(data, target)
        guard try io.read(target) == data else { throw PlannerError("Recovery file verification failed.") }
    }

    /// A save fails closed if the previous revision cannot be validated and backed up.
    func save(_ planner: Planner) throws { try withLock { try saveLocked(planner) } }

    private func saveLocked(_ planner: Planner) throws {
        let data = try Self.encoder.encode(PlannerDiskDocument(planner))
        // Validate both representations before any side effect, including preference migration.
        _ = try Self.decode(data)
        let current = try readIfPresent(url)
        if let current {
            let document: PlannerDiskDocument
            do { document = try Self.decoder.decode(PlannerDiskDocument.self, from: current) } catch let error
                as PlannerSchemaError
            { throw error } catch {
                throw PlannerDataError.corrupt(
                    url: url, quarantineURL: nil,
                    reason: "Reload to inspect preserved records before saving")
            }
            if document.sourceVersion < PlannerDiskDocument.currentVersion {
                try preserveMigrationLocked(current)
            }
            if current != data { try backUpLocked(current) }
        }
        let previous = try preferences.load()
        let desired = DevicePreferences(planner.preferences)
        if previous != desired { try preferences.save(desired) }
        do {
            if current != data { try io.write(data, url) }
        } catch {
            // Normal write failures must not commit a preference-only half transaction.
            do { if previous != desired { try preferences.save(previous) } } catch {
                throw PlannerError("Planner write and preference rollback failed. Recovery backups were retained.")
            }
            throw error
        }
    }

    private func preserveMigrationLocked(_ data: Data) throws {
        try FileManager.default.createDirectory(at: migrationDirectory, withIntermediateDirectories: true)
        for existing in try FileManager.default.contentsOfDirectory(
            at: migrationDirectory, includingPropertiesForKeys: nil)
        where existing.pathExtension == "json" {
            if (try? io.read(existing)) == data { return }
        }
        let copy = migrationDirectory.appendingPathComponent("version-1-\(UUID().uuidString).json")
        try io.write(data, copy)
        guard try io.read(copy) == data else {
            throw PlannerError("Migration backup verification failed. The original was not changed.")
        }
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
        guard number < UInt64.max else {
            throw PlannerError("Planner backup sequence is full; the original was not changed.")
        }
        let name =
            "backup-" + String(repeating: "0", count: 20 - String(number + 1).count) + String(number + 1) + ".json"
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
            throw PlannerError(
                "Planner backup retention failed: \(error.localizedDescription). The original was not changed.")
        }
    }

    /// Explicit recovery only: choose the newest readable, decodable backup. Never
    /// silently fall back to empty data or overwrite an unreadable current file.
    @discardableResult
    func restoreLatestBackup() throws -> Planner {
        try withLock {
            var candidate: (Data, Planner)?
            for backup in try backupURLsLocked() {
                if let data = try? io.read(backup), let planner = try? Self.decode(data) {
                    candidate = (data, planner)
                    break
                }
            }
            guard let (data, planner) = candidate else {
                throw PlannerError("No readable, valid planner backup is available.")
            }
            let restored = try applyingPreferences(to: planner)
            if let current = try readIfPresent(url) {
                // A newer schema is not corrupt and must never be downgraded by restore.
                do { _ = try Self.decode(current) } catch let error as PlannerSchemaError { throw error } catch
                { /* Corrupt current data is preserved below before explicit restore. */  }
                if current == data { return restored }
                if (try? Self.decode(current)) != nil {
                    try backUpLocked(current)
                } else {
                    _ = try preserveCorruptCurrent(current)
                }
            }
            try io.write(data, url)
            return restored
        }
    }

    /// Exclusive read-modify-write across processes. Internal helpers avoid nested locks.
    @discardableResult
    func mutate<T>(_ body: (inout Planner) throws -> T) throws -> T {
        try withLock {
            var p = try applyingPreferences(to: loadLocked())
            let before = p
            let result = try body(&p)
            let needsMigration =
                try readIfPresent(url).map {
                    (try Self.decoder.decode(SchemaVersion.self, from: $0).version ?? 1)
                        < PlannerDiskDocument.currentVersion
                } ?? false
            if p != before || needsMigration { try saveLocked(p) }
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
                try saveLocked(applyingPreferences(to: planner))
            } else {
                try Self.encoder.encode(PlannerExportDocument(planner: planner)).write(to: dest, options: .atomic)
            }
        }
    }
}
