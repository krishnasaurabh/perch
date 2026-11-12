import Foundation

/// Resolves shipped resources without invoking SwiftPM's fatal bundle accessor.
/// Installed apps are self-contained; test executables may use adjacent bundles.
enum LocalizationResources {
    private final class CodeBundleMarker: NSObject {}

    static func catalogURL(bundleName: String) -> URL? {
        let main = Bundle.main
        let code = Bundle(for: CodeBundleMarker.self)
        return catalogURL(
            bundleName: bundleName, resourceDirectory: main.resourceURL,
            bundleDirectory: main.bundleURL, codeResourceDirectory: code.resourceURL,
            codeBundleDirectory: code.bundleURL)
    }

    static func catalogURL(
        bundleName: String, resourceDirectory: URL?, bundleDirectory: URL,
        codeResourceDirectory: URL? = nil, codeBundleDirectory: URL? = nil
    ) -> URL? {
        // Prefer the module's catalog in Apple's installed-app layout, then the
        // executable-bundle layout, then the main bundle's compiled catalog.
        var directories = [
            resourceDirectory?.appendingPathComponent(bundleName),
            bundleDirectory.appendingPathComponent(bundleName),
            resourceDirectory,
        ].compactMap { $0 }
        if bundleDirectory.pathExtension != "app" {
            directories.append(bundleDirectory.deletingLastPathComponent().appendingPathComponent(bundleName))
            directories += [
                codeResourceDirectory?.appendingPathComponent(bundleName),
                codeBundleDirectory?.appendingPathComponent(bundleName),
                codeBundleDirectory?.deletingLastPathComponent().appendingPathComponent(bundleName),
            ].compactMap { $0 }
        }
        return directories.lazy.compactMap { catalogURL(in: $0) }.first
    }

    static func catalogURL(in directory: URL) -> URL? {
        // SwiftPM uses both flat bundles and standard macOS resource bundles.
        for relative in ["Contents/Resources/Localizable.json", "Localizable.json"] {
            let url = directory.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return url
            }
        }
        return nil
    }
}
