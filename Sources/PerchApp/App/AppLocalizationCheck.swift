#if DEBUG || PERCH_TESTING
    import Foundation
    import PerchUI

    /// Tests the packaged executable before any storage or platform services open.
    enum AppLocalizationCheck {
        static func run() throws {
            let english = Locale(identifier: "en")
            let pseudo = Locale(identifier: "zz")
            let values = [
                "appEnglish": AppL10n.format("%lld tasks", locale: english, 1),
                "appPseudo": AppL10n.format("%lld tasks", locale: pseudo, 2),
                "uiEnglish": PerchL10n.tasks(count: 1, locale: english),
                "uiPseudo": PerchL10n.tasks(count: 2, locale: pseudo),
            ]
            let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
#endif
