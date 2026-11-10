import Foundation
import PlannerCore

/// Errors shown by the app's shared banner. Associated values are presentation details, not task content.
enum PerchAppError: Error, Equatable {
    case planner(String)
    case reminderScheduling(String)
    case loginItem(String)
    case remindersPermission
    case aiSorting(String)

    var message: String {
        switch self {
        case .planner(let detail): detail
        case .aiSorting(let detail): "AI sorting failed: \(detail)"
        case .reminderScheduling(let detail): "Reminder scheduling failed: \(detail)"
        case .loginItem(let detail): "Perch couldn't update the login item: \(detail)"
        case .remindersPermission:
            "Perch has no Reminders permission. Grant it under System Settings › Privacy & Security › Reminders."
        }
    }
}

extension PerchAppError: LocalizedError {
    var errorDescription: String? { message }
}

extension Error {
    var perchPresentationDetail: String {
        (self as? PlannerError)?.message ?? localizedDescription
    }
}

/// Notification authorization and scheduling failures retain separate adapter context.
enum ReminderServiceError: Error, Equatable {
    case authorization(String)
    case scheduling(String)

    var message: String {
        switch self {
        case .authorization(let detail): "Notification permission failed: \(detail)"
        case .scheduling(let detail): "Reminder scheduling failed: \(detail)"
        }
    }
}

extension ReminderServiceError: LocalizedError {
    var errorDescription: String? { message }
}

/// Reminders sync states that must stay visible even when no planner mutation occurs.
enum RemindersSyncFailure: Error, Equatable {
    case consentRequired
    case access(String)
    case historyPaused
    case sync(String)
    case disableAfterHistory(String)

    static let consentMessage =
        "Reminders sync is paused. Turn it off and on in Settings to enable safe mirroring. Existing reminders will not be adopted or changed."
    static let historyMessage =
        "Reminders sync paused after Undo or Redo. Your reminders were not changed. Turn sync off and on in Settings when ready to mirror this version."

    var message: String {
        switch self {
        case .consentRequired: Self.consentMessage
        case .access(let detail): detail
        case .historyPaused: Self.historyMessage
        case .sync(let detail): "Reminders sync stopped: \(detail)"
        case .disableAfterHistory(let detail): Self.historyMessage + " " + detail
        }
    }
}

extension RemindersSyncFailure: LocalizedError {
    var errorDescription: String? { message }
}
