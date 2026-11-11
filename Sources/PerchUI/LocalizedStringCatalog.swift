import Foundation

/// Portable catalog reader used by Linux tests. macOS uses Foundation's native
/// string-catalog lookup; both paths read the same authored English/pseudo data.
public enum LocalizedStringCatalog {
    public static func text(
        _ key: String, locale: Locale? = nil, bundle: Bundle? = nil, numericArgument: Int? = nil
    ) -> String {
        let bundle = bundle ?? .module
        #if os(macOS)
            return String(localized: String.LocalizationValue(key), locale: locale, bundle: bundle)
        #else
            return portableText(key, locale: locale, bundle: bundle, numericArgument: numericArgument)
        #endif
    }

    #if !os(macOS)
        private struct Document: Decodable { let strings: [String: Entry] }
        private struct Entry: Decodable { let localizations: [String: Localization] }
        private struct Localization: Decodable {
            let stringUnit: StringUnit?
            let variations: Variations?
        }
        private struct Variations: Decodable { let plural: [String: VariationUnit]? }
        private struct VariationUnit: Decodable { let stringUnit: StringUnit }
        private struct StringUnit: Decodable { let value: String }

        private static func portableText(
            _ key: String, locale: Locale?, bundle: Bundle, numericArgument: Int?
        ) -> String {
            guard let url = bundle.url(forResource: "Localizable", withExtension: "json"),
                let data = try? Data(contentsOf: url),
                let document = try? JSONDecoder().decode(Document.self, from: data),
                let entry = document.strings[key]
            else { return key }
            let identifier = locale?.language.languageCode?.identifier ?? "en"
            let language = identifier == "zz" ? "zz" : "en"
            guard let localization = entry.localizations[language] else { return key }
            if let value = localization.stringUnit?.value { return value }
            let category = numericArgument == 1 ? "one" : "other"
            return localization.variations?.plural?[category]?.stringUnit.value ?? key
        }
    #endif
}
