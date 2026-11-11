import Foundation

/// Reads the same authored JSON catalog in tests and in the bundled app. SwiftPM
/// copies `.xcstrings` as data rather than compiling it, so runtime lookup must not
/// depend on Xcode-only catalog compilation.
public enum LocalizedStringCatalog {
    public static func text(
        _ key: String, locale: Locale? = nil, bundle: Bundle? = nil, numericArgument: Int? = nil
    ) -> String {
        portableText(
            key, locale: locale, bundle: bundle ?? .module, numericArgument: numericArgument)
    }

    private struct Document: Decodable { let strings: [String: Entry] }
    private struct Entry: Decodable { let localizations: [String: Localization] }
    private struct Localization: Decodable {
        let stringUnit: StringUnit?
        let variations: Variations?
    }
    private struct Variations: Decodable { let plural: [String: VariationUnit]? }
    private struct VariationUnit: Decodable { let stringUnit: StringUnit }
    private struct StringUnit: Decodable { let value: String }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var documents: [ObjectIdentifier: Document] = [:]

        func document(for bundle: Bundle) -> Document? {
            let identifier = ObjectIdentifier(bundle)
            lock.lock()
            if let cached = documents[identifier] {
                lock.unlock()
                return cached
            }
            lock.unlock()
            guard let url = bundle.url(forResource: "Localizable", withExtension: "json"),
                let data = try? Data(contentsOf: url),
                let decoded = try? JSONDecoder().decode(Document.self, from: data)
            else { return nil }
            lock.lock()
            documents[identifier] = decoded
            lock.unlock()
            return decoded
        }
    }
    private static let cache = Cache()

    private static func portableText(
        _ key: String, locale: Locale?, bundle: Bundle, numericArgument: Int?
    ) -> String {
        guard let document = cache.document(for: bundle), let entry = document.strings[key] else { return key }
        let identifier = locale?.language.languageCode?.identifier ?? Locale.current.language.languageCode?.identifier
        let language = identifier == "zz" ? "zz" : "en"
        guard let localization = entry.localizations[language] else { return key }
        if let value = localization.stringUnit?.value { return value }
        let category = numericArgument == 1 ? "one" : "other"
        return localization.variations?.plural?[category]?.stringUnit.value ?? key
    }
}
