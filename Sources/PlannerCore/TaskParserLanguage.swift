import Foundation

/// Languages whose natural-language task grammar is implemented and tested.
/// This is deliberately independent of the interface's presentation locale.
public enum TaskParserLanguage: String, CaseIterable, Sendable {
    case english = "en"

    /// The pseudolocalization locale exercises expansion and RTL layout while
    /// continuing to use the explicitly selected English task grammar.
    public static let pseudolocalizationIdentifier = "zz"

    public init?(languageCode: String) {
        let normalized = languageCode.replacingOccurrences(of: "_", with: "-").lowercased()
        let base = normalized.split(separator: "-").first.map(String.init) ?? normalized
        if base == Self.pseudolocalizationIdentifier {
            self = .english
        } else {
            self.init(rawValue: base)
        }
    }

    public static var current: TaskParserLanguage? {
        TaskParserLanguage(languageCode: Locale.current.language.languageCode?.identifier ?? "")
    }

    public var displayName: String {
        switch self {
        case .english: "English"
        }
    }
}

public struct UnsupportedTaskParserLanguage: Error, Equatable, Sendable {
    public let languageCode: String
    public init(languageCode: String) { self.languageCode = languageCode }
}

extension TaskCapture {
    /// Parses with an explicit supported grammar. No locale guessing or fallback
    /// to English occurs for an unsupported presentation language.
    public func parse(_ input: String, language: TaskParserLanguage) -> CapturedTask {
        // A single case today; keeping the language on the API prevents an
        // unsupported interface locale from silently changing stored tasks.
        switch language {
        case .english: parse(input)
        }
    }

    public func parse(_ input: String, languageCode: String) throws -> CapturedTask {
        guard let language = TaskParserLanguage(languageCode: languageCode) else {
            throw UnsupportedTaskParserLanguage(languageCode: languageCode)
        }
        return parse(input, language: language)
    }
}
