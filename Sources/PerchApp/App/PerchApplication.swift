import AppKit
import PlannerCore
import PerchMCP

public enum PerchApplication {
    public static func run() {
        do {
            try AppLaunchConfiguration.validate(
                arguments: Array(CommandLine.arguments.dropFirst()),
                environment: ProcessInfo.processInfo.environment)
        } catch {
            FileHandle.standardError.write(Data("Unsupported or invalid launch configuration.\n".utf8))
            exit(64)
        }
        #if DEBUG || PERCH_TESTING
            if CommandLine.arguments.contains("--check-localization") {
                do {
                    try AppLocalizationCheck.run()
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("Localization check failed.\n".utf8))
                    exit(1)
                }
            }
        #endif
        // One binary, two modes:
        //   Perch.app/Contents/MacOS/Perch          -> the notch app
        //   Perch.app/Contents/MacOS/Perch --mcp    -> stdio MCP server for Claude Code / Claude app / Cursor
        if CommandLine.arguments.contains("--mcp") {
            let server = MCPServer(tools: AgentTools(file: PlannerFile()), version: AppInfo.version)
            server.onChange = {
                // Tell a running app to reload right away (it also watches the file).
                DistributedNotificationCenter.default().postNotificationName(
                    .init("app.perch.mac.plannerChanged"), object: nil, userInfo: nil, deliverImmediately: true)
            }
            server.runStdio()
            exit(0)
        }

        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)  // no Dock icon, like LSUIElement
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}
