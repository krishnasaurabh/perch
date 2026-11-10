import Foundation
import PerchUI

/// App-owned sidecar: no task text, no change to the planner's schema or backups.
struct ReminderLedger {
    let url: URL

    func load() throws -> [String: ReminderRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: ReminderRecord].self, from: Data(contentsOf: url))
    }

    func save(_ records: [String: ReminderRecord]) throws {
        if try load() == records { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
    }
}
