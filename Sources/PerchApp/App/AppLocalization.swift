import Foundation
import PerchUI
import PlannerCore

/// App-layer strings use the same catalog in SwiftPM probes and the bundled app.
enum AppL10n {
    static func text(_ key: String, locale: Locale? = nil) -> String {
        LocalizedStringCatalog.text(key, locale: locale, bundle: .module)
    }

    static func format(_ key: String, locale: Locale? = nil, _ arguments: CVarArg...) -> String {
        let numeric: Int?
        switch arguments.first {
        case let value as Int: numeric = value
        case let value as Int64: numeric = Int(value)
        case let value as Double: numeric = Int(value)
        default: numeric = nil
        }
        let template = LocalizedStringCatalog.text(key, locale: locale, bundle: .module, numericArgument: numeric)
        return String(format: template, locale: locale, arguments: arguments)
    }

    static var parserLanguage: TaskParserLanguage? { TaskParserLanguage.current }

    static func priority(_ priority: TaskPriority, locale: Locale? = nil) -> String {
        switch priority {
        case .none: AppL10n.text("None", locale: locale)
        case .low: AppL10n.text("Low", locale: locale)
        case .medium: AppL10n.text("Medium", locale: locale)
        case .high: AppL10n.text("High", locale: locale)
        }
    }

    static func plannerMessage(_ error: PlannerError, locale: Locale? = nil) -> String {
        guard let key = error.presentationKey else { return text(error.message, locale: locale) }
        let template = text(key, locale: locale)
        return String(format: template, locale: locale, arguments: error.presentationArguments.map { $0 as CVarArg })
    }
}
