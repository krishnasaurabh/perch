import Foundation

/// Validates the app entry point before storage or platform services are opened.
/// The scriptable CLI has its own command parser; the app preserves its `--mcp` mode.
public enum AppLaunchConfiguration {
    public enum Invalid: Error { case argument, value, requiresIsolatedData, requiresDriver }

    public static func validate(arguments: [String], environment: [String: String]) throws {
        var options = Set<String>()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            // LaunchServices can supply single-dash Cocoa arguments. They are not app options.
            guard argument.hasPrefix("--") else { continue }
            guard options.insert(argument).inserted else { throw Invalid.argument }
            if argument == "--mcp" { continue }
            #if DEBUG || PERCH_TESTING
                switch argument {
                case "--demo", "--demo-clips", "--preview-open", "--check-localization": break
                case "--scenario", "--page", "--dump-layout", "--dump-activity", "--snapshot",
                    "--motion-script", "--motion-snapshots", "--motion-policy":
                    guard index < arguments.count, !arguments[index].isEmpty,
                        !arguments[index].hasPrefix("--")
                    else { throw Invalid.value }
                    let value = arguments[index]
                    index += 1
                    switch argument {
                    case "--scenario":
                        guard ["empty", "three", "timer", "insights"].contains(value) else { throw Invalid.value }
                    case "--page":
                        guard ["home", "week", "clips", "insights"].contains(value) else { throw Invalid.value }
                    case "--motion-policy":
                        guard ["production", "normal", "reduced"].contains(value) else { throw Invalid.value }
                    default: break
                    }
                default: throw Invalid.argument
                }
            #else
                throw Invalid.argument
            #endif
        }
        #if DEBUG || PERCH_TESTING
            let hasHooks =
                !options.subtracting(["--mcp"]).isEmpty
                || environment["PERCH_SCREENSHOT_FOLDER"] != nil
                || environment.keys.contains(where: { $0.hasPrefix("PERCH_MOTION_") })
            if hasHooks {
                guard let data = environment["PERCH_DATA"], data.hasPrefix("/"), data != "/" else {
                    throw Invalid.requiresIsolatedData
                }
                guard !options.contains("--mcp") else { throw Invalid.argument }
            }
            if options.contains("--check-localization"), options.count != 1 { throw Invalid.argument }
            if !options.isDisjoint(with: ["--motion-policy", "--motion-snapshots"]),
                !options.contains("--motion-script")
            {
                throw Invalid.requiresDriver
            }
            if options.contains("--page"), !options.contains("--preview-open") { throw Invalid.requiresDriver }
            if options.contains("--demo"), options.contains("--scenario") { throw Invalid.argument }
        #endif
    }
}
