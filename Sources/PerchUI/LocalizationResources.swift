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
        // SwiftPM's module identity is stable, but its resource container can be
        // either a .bundle or a plain .resources directory, without bundle metadata.
        let moduleName = (bundleName as NSString).deletingPathExtension
        let containerNames =
            [bundleName]
            + ["bundle", "resources"]
            .map { "\(moduleName).\($0)" }.filter { $0 != bundleName }
        func moduleDirectories(in root: URL?) -> [URL] {
            guard let root else { return [] }
            return containerNames.map { root.appendingPathComponent($0) }
        }

        // Exhaust container variants at each location before falling back to a
        // lower-priority location or the main bundle's compiled catalog.
        var directories =
            moduleDirectories(in: resourceDirectory)
            + moduleDirectories(in: bundleDirectory)
            + [resourceDirectory].compactMap { $0 }
        if bundleDirectory.pathExtension != "app" {
            directories +=
                moduleDirectories(in: bundleDirectory.deletingLastPathComponent())
                + moduleDirectories(in: codeResourceDirectory)
                + moduleDirectories(in: codeBundleDirectory)
                + moduleDirectories(in: codeBundleDirectory?.deletingLastPathComponent())
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
