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

    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["PERCH_DATA"] { return URL(fileURLWithPath: override) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share")
        return base.appendingPathComponent("Perch/planner.json")
    }

    public init(url: URL = PlannerFile.defaultURL) {
        self.url = url
        lockURL = url.appendingPathExtension("lock")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(PlannerDateCoding.string(date))
        }
        return e
    }()

    static let decoder: JSONDecoder = {
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
    }()

    /// Loads the planner. A corrupt file is preserved next to the original and an empty planner is returned.
    public func load() throws -> Planner {
        guard FileManager.default.fileExists(atPath: url.path) else { return Planner() }
        let data = try Data(contentsOf: url)
        do {
            return try Self.decoder.decode(Planner.self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
            try? FileManager.default.copyItem(at: url, to: backup)
            throw PlannerError("Unable to load planner data. A recovery copy is saved at \(backup.path)")
        }
    }

    public func save(_ planner: Planner) throws {
        let data = try Self.encoder.encode(planner)
        try data.write(to: url, options: .atomic)
    }

    /// Exclusive read-modify-write across processes.
    @discardableResult
    public func mutate<T>(_ body: (inout Planner) throws -> T) throws -> T {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw PlannerError("Planner storage lock could not be opened.") }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        var p = try load()
        let before = p
        let result = try body(&p)
        if p != before { try save(p) }
        return result
    }

    public var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    /// JSON export for "Export planner data".
    public func export(to dest: URL) throws {
        try Self.encoder.encode(try load()).write(to: dest, options: .atomic)
    }
}
