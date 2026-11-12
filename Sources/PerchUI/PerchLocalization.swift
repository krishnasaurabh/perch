import Foundation
import PlannerCore

/// Shared presentation strings. Storage and transport text never pass through here.
public enum PerchL10n {
    public static func text(_ key: String, locale: Locale? = nil) -> String {
        LocalizedStringCatalog.text(key, locale: locale)
    }

    public static func format(_ key: String, locale: Locale? = nil, _ arguments: CVarArg...) -> String {
        let locale = locale ?? .current
        let numeric: Int?
        switch arguments.first {
        case let value as Int: numeric = value
        case let value as Int64: numeric = Int(value)
        case let value as Double: numeric = Int(value)
        default: numeric = nil
        }
        let template = LocalizedStringCatalog.text(
            key, locale: locale, numericArgument: numeric)
        return String(format: template, locale: locale, arguments: arguments)
    }

    public static func number(_ value: Int, locale: Locale = .current) -> String {
        value.formatted(.number.locale(locale))
    }

    public static func tasks(count: Int, capped: Bool = false, locale: Locale? = nil) -> String {
        if capped && count > 999 { return text("999+ tasks", locale: locale) }
        return format("%lld tasks", locale: locale, count)
    }

    /// Deterministic QA metadata; this is not a translation or a supported parser language.
    public static func isPseudolocalization(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier == TaskParserLanguage.pseudolocalizationIdentifier
    }
}

/// Layout policy shared by localization fixtures and native smoke probes.
public enum LocalizedLayout {
    public enum TextDirection: Equatable, Sendable { case leftToRight, rightToLeft }

    public static func direction(for locale: Locale) -> TextDirection {
        switch locale.language.languageCode?.identifier {
        case "ar", "fa", "he", "ur": .rightToLeft
        default: .leftToRight
        }
    }

    public static func requiresWrappedContent(english: String, presented: String) -> Bool {
        presented.count > english.count || presented.contains("\n")
    }

    public static func fittingWidth(base: Double, dynamicTypeScale: Double, expansion: Double = 1) -> Double {
        base * max(1, dynamicTypeScale) * max(1, expansion)
    }
}
