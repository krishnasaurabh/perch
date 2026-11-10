import Foundation
import OSLog

/// Structured adapter diagnostics. Only operation names, identifiers, counts and numeric error codes are public.
/// Task text, clipboard data, authorization tokens, network addresses and filesystem paths never enter these logs.
enum PlatformLog {
    static let calendar = Logger(subsystem: "app.perch.mac", category: "CalendarAccess")
    static let reminders = Logger(subsystem: "app.perch.mac", category: "RemindersAccess")
    static let notifications = Logger(subsystem: "app.perch.mac", category: "NotificationAccess")
    static let pasteboard = Logger(subsystem: "app.perch.mac", category: "PasteboardAccess")
    static let speech = Logger(subsystem: "app.perch.mac", category: "SpeechAuthorization")
    static let folders = Logger(subsystem: "app.perch.mac", category: "FolderWatcher")
    static let hotKey = Logger(subsystem: "app.perch.mac", category: "GlobalHotKey")
    static let agents = Logger(subsystem: "app.perch.mac", category: "AgentConnector")
    static let sorting = Logger(subsystem: "app.perch.mac", category: "AISorter")

    static func errorCode(_ error: Error) -> Int { (error as NSError).code }
}
