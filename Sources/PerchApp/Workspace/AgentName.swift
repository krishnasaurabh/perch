import Foundation

/// Turns an MCP `clientInfo.name` (what `PlanTask.agentID` stores) into a short
/// label for the provenance chip. Unknown clients fall back to their first word.
enum AgentName {
    static func short(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let lower = name.lowercased()
        // Ordered: "claude-code" must read as Claude, not Code.
        let known: [(needle: String, label: String)] = [
            ("claude", "Claude"), ("cursor", "Cursor"), ("codex", "Codex"),
            ("opencode", "OpenCode"), ("windsurf", "Windsurf"),
            ("copilot", "Copilot"), ("chatgpt", "ChatGPT"),
        ]
        if let hit = known.first(where: { lower.contains($0.needle) }) { return hit.label }
        let parts = name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " || $0 == "." })
        // Short needles only match a whole token ("zed-agent", not "personalized").
        if parts.contains(where: { $0.lowercased() == "zed" }) { return "Zed" }
        let word = parts.first.map(String.init) ?? name
        return word.count > 14 ? String(word.prefix(13)) + "…" : word.prefix(1).uppercased() + word.dropFirst()
    }
}
