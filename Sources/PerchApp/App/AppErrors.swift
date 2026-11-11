import Foundation
import PlannerCore

/// Errors shown by the app's shared banner. Associated values are presentation details, not task content.
enum PerchAppError: Error, Equatable {
    case planner(String)
    case reminderScheduling(String)
    case loginItem(String)
    case remindersPermission
    case aiSorting(String)
    case unsupportedParserLanguage(String)

    var message: String {
        switch self {
        case .planner(let detail): detail
        case .aiSorting(let detail): AppL10n.format("AI sorting failed: %@", detail)
        case .reminderScheduling(let detail): AppL10n.format("Reminder scheduling failed: %@", detail)
        case .loginItem(let detail): AppL10n.format("Perch couldn't update the login item: %@", detail)
        case .remindersPermission:
            AppL10n.text(
                "Perch has no Reminders permission. Grant it under System Settings › Privacy & Security › Reminders.")
        case .unsupportedParserLanguage(let code):
            AppL10n.format(
                "Task entry currently supports English. The selected language (%@) is not supported, so nothing was added. Choose English for task entry or change the app language.",
                code.isEmpty ? AppL10n.text("Unknown") : code)
        }
    }
}

extension PerchAppError: LocalizedError {
    var errorDescription: String? { message }
}

extension Error {
    var perchPresentationDetail: String {
        if let unsupported = self as? UnsupportedTaskParserLanguage {
            return PerchAppError.unsupportedParserLanguage(unsupported.languageCode).message
        }
        if let planner = self as? PlannerError {
            return AppL10n.plannerMessage(planner)
        }
        return AppL10n.text(localizedDescription)
    }
}

/// Notification authorization and scheduling failures retain separate adapter context.
enum ReminderServiceError: Error, Equatable {
    case authorization(String)
    case scheduling(String)

    var message: String {
        switch self {
        case .authorization(let detail): AppL10n.format("Notification permission failed: %@", detail)
        case .scheduling(let detail): AppL10n.format("Reminder scheduling failed: %@", detail)
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

    static var consentMessage: String {
        AppL10n.text(
            "Reminders sync is paused. Turn it off and on in Settings to enable safe mirroring. Existing reminders will not be adopted or changed."
        )
    }
    static var historyMessage: String {
        AppL10n.text(
            "Reminders sync paused after Undo or Redo. Your reminders were not changed. Turn sync off and on in Settings when ready to mirror this version."
        )
    }

    var message: String {
        switch self {
        case .consentRequired: Self.consentMessage
        case .access(let detail): AppL10n.text(detail)
        case .historyPaused: Self.historyMessage
        case .sync(let detail): AppL10n.format("Reminders sync stopped: %@", detail)
        case .disableAfterHistory(let detail): Self.historyMessage + " " + detail
        }
    }
}

extension RemindersSyncFailure: LocalizedError {
    var errorDescription: String? { message }
}
