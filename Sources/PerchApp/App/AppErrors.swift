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

    var message: String { message(locale: nil) }

    func message(locale: Locale?) -> String {
        switch self {
        case .planner(let detail): detail
        case .aiSorting(let detail): AppL10n.format("AI sorting failed: %@", locale: locale, detail)
        case .reminderScheduling(let detail):
            AppL10n.format("Reminder scheduling failed: %@", locale: locale, detail)
        case .loginItem(let detail):
            AppL10n.format("Perch couldn't update the login item: %@", locale: locale, detail)
        case .remindersPermission:
            AppL10n.text(
                "Perch has no Reminders permission. Grant it under System Settings › Privacy & Security › Reminders.",
                locale: locale)
        case .unsupportedParserLanguage(let code):
            AppL10n.format(
                "Task entry currently supports English. The selected language (%@) is not supported, so nothing was added. Choose English for task entry or change the app language.",
                locale: locale, code.isEmpty ? AppL10n.text("Unknown", locale: locale) : code)
        }
    }
}

extension PerchAppError: LocalizedError {
    var errorDescription: String? { message }
}

extension Error {
    var perchPresentationDetail: String { perchPresentationDetail(locale: nil) }

    func perchPresentationDetail(locale: Locale? = nil) -> String {
        if let unsupported = self as? UnsupportedTaskParserLanguage {
            return PerchAppError.unsupportedParserLanguage(unsupported.languageCode).message(locale: locale)
        }
        if let planner = self as? PlannerError {
            return AppL10n.plannerMessage(planner, locale: locale)
        }
        if self is PlannerStorageBusy {
            return AppL10n.text("Another process is updating the planner. Please try again.", locale: locale)
        }
        if let data = self as? PlannerDataError {
            switch data {
            case let .unreadable(url, reason):
                return AppL10n.format(
                    "Unable to read planner data at %@: %@. The original was not changed; check file access before retrying. No empty or reduced planner was saved.",
                    locale: locale, url.path, reason)
            case let .corrupt(url, quarantineURL, reason):
                if let quarantineURL {
                    return AppL10n.format(
                        "Unable to load planner data at %@: %@. The original is unchanged. An exact recovery copy is saved at %@. No reduced planner was loaded or saved over the original. Quit Perch and repair the file or explicitly restore a known-good backup before saving.",
                        locale: locale, url.path, reason, quarantineURL.path)
                }
                return AppL10n.format(
                    "Unable to load planner data at %@: %@. The original is unchanged. No reduced planner was loaded or saved over the original. Quit Perch and repair the file or explicitly restore a known-good backup before saving.",
                    locale: locale, url.path, reason)
            }
        }
        if let schema = self as? PlannerSchemaError {
            return AppL10n.format(
                "Planner schema version %lld is not supported by this document reader. Open it with a compatible Perch version. No data was rewritten or restored.",
                locale: locale, schema.version)
        }
        if let recovery = self as? PlannerRecoveryError {
            return AppL10n.format(
                "Planner data needs recovery. Kept %lld valid record(s) in a read-only draft. Quarantined %lld invalid record(s) and %lld invalid field(s). Valid records are available read-only; changes cannot be saved. The original planner is unchanged. An exact copy, including malformed records, is at %@. A separate valid-record draft is at %@; rejected locations are listed at %@. Quit Perch and repair the original using those files, or explicitly restore a known-good backup. Do not replace the original with the draft unless you accept omitting the rejected records.",
                locale: locale, recovery.keptCount, recovery.quarantinedCount, recovery.quarantinedFieldCount,
                recovery.quarantineURL.path, recovery.recoveredURL.path, recovery.issuesURL.path)
        }
        return AppL10n.text(localizedDescription, locale: locale)
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
        case .access(let detail): Self.presentedDetail(detail)
        case .historyPaused: Self.historyMessage
        case .sync(let detail): AppL10n.format("Reminders sync stopped: %@", Self.presentedDetail(detail))
        case .disableAfterHistory(let detail): Self.historyMessage + " " + Self.presentedDetail(detail)
        }
    }

    /// Owned recovery details resolve through the catalog; unknown system details remain verbatim.
    static func presentedDetail(_ detail: String, locale: Locale? = nil) -> String {
        AppL10n.text(detail, locale: locale)
    }
}

extension RemindersSyncFailure: LocalizedError {
    var errorDescription: String? { message }
}
