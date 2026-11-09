import AppKit
import Foundation
import PlannerCore

/// Connects Perch's MCP server to Claude Code, the Claude app and Cursor, no Terminal needed.
enum AgentConnector {
    enum App: String, CaseIterable, Identifiable {
        case claudeCode, claudeApp, cursor
        var id: String { rawValue }
        var name: String { ["claudeCode": "Claude Code", "claudeApp": "Claude app", "cursor": "Cursor"][rawValue]! }
    }

    enum Status: Equatable { case connected, notConnected, notInstalled }

    static let serverName = "perch"
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var claudeDesktopConfig: URL { home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json") }
    static var cursorConfig: URL { home.appendingPathComponent(".cursor/mcp.json") }
    static var claudeCodeConfig: URL { home.appendingPathComponent(".claude.json") }

    static let claudeCandidates = [
        "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        "~/.local/bin/claude", "~/.claude/local/claude", "~/.npm-global/bin/claude",
    ].map { NSString(string: $0).expandingTildeInPath }

    static var claudeBinary: String? { claudeCandidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    static var terminalCommand: String {
        "claude mcp add --scope user \(serverName) -- \"\(AppInfo.executablePath)\" --mcp"
    }

    static func status(_ app: App) -> Status {
        switch app {
        case .claudeCode:
            guard claudeBinary != nil else { return .notInstalled }
            return jsonHasServer(claudeCodeConfig, path: ["mcpServers"]) ? .connected : .notConnected
        case .claudeApp:
            let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") != nil
            guard installed || FileManager.default.fileExists(atPath: claudeDesktopConfig.path) else { return .notInstalled }
            return jsonHasServer(claudeDesktopConfig, path: ["mcpServers"]) ? .connected : .notConnected
        case .cursor:
            let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") != nil
            guard installed || FileManager.default.fileExists(atPath: cursorConfig.path) else { return .notInstalled }
            return jsonHasServer(cursorConfig, path: ["mcpServers"]) ? .connected : .notConnected
        }
    }

    /// Returns a message for the user.
    static func connect(_ app: App) throws -> String {
        guard AppInfo.isInApplications else { throw PlannerError("Install Perch in Applications before connecting an agent.") }
        switch app {
        case .claudeCode:
            guard let bin = claudeBinary else { throw PlannerError("Claude Code isn't installed.") }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["mcp", "add", "--scope", "user", serverName, "--", AppInfo.executablePath, "--mcp"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            p.environment = env
            let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
            try p.run(); p.waitUntilExit()
            if p.terminationStatus != 0 {
                let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if msg.contains("already exists") { return "Perch is already connected to Claude Code." }
                throw PlannerError("Adding Perch to Claude Code failed. \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return "Open a fresh Claude Code session, then ask it something like:"
        case .claudeApp:
            try addServer(to: claudeDesktopConfig)
            return "Quit and reopen the Claude app, then ask it something like:"
        case .cursor:
            try addServer(to: cursorConfig)
            return "Cursor loads Perch when it restarts."
        }
    }

    static func disconnect(_ app: App) throws {
        switch app {
        case .claudeCode:
            guard let bin = claudeBinary else { return }
            let p = Process(); p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["mcp", "remove", "--scope", "user", serverName]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
        case .claudeApp: try removeServer(from: claudeDesktopConfig)
        case .cursor: try removeServer(from: cursorConfig)
        }
    }

    // MARK: JSON config editing. An unreadable file is left untouched.

    static func addServer(to url: URL) throws {
        var root = try readConfig(url)
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = ["command": AppInfo.executablePath, "args": ["--mcp"]]
        root["mcpServers"] = servers
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url.appendingPathExtension("perch-backup"))
            try? FileManager.default.copyItem(at: url, to: url.appendingPathExtension("perch-backup"))
        }
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    static func removeServer(from url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var root = try readConfig(url)
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = nil
        root["mcpServers"] = servers
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    static func readConfig(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlannerError("\(url.lastPathComponent) couldn't be read, so Perch left it unchanged.")
        }
        return obj
    }

    static func jsonHasServer(_ url: URL, path: [String]) -> Bool {
        guard let root = try? readConfig(url) else { return false }
        // Claude Code keeps user-scope servers under the top-level "mcpServers" of ~/.claude.json, same key as the others.
        return (root["mcpServers"] as? [String: Any])?[serverName] != nil
    }

    static let examplePrompts = [
        "What's on my Perch list today?",
        "Add \"text dad tomorrow at 6pm !high\" to Perch",
        "Put code review, a walk and laundry on my Perch list for today",
        "Give me 20 minutes of focus time in Perch",
        "Show my completed tasks and focus time for this week in Perch",
    ]
}
