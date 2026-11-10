import AppKit
import SwiftUI

struct AgentsSettings: View {
    @EnvironmentObject var store: PlannerStore
    @State private var statuses: [AgentConnector.App: AgentConnector.Status] = [:]
    @State private var message: String?
    @State private var copied: String?

    var body: some View {
        Section("Connect AI agents") {
            Text(
                "One-time setup that lets Claude read and edit your plan, tick tasks off and run timers. The MCP server runs inside Perch on this Mac, with no network hop."
            )
            .font(.caption).foregroundStyle(.secondary)
            if !AppInfo.isInApplications {
                Label(
                    "Agent setup requires Perch to be installed in Applications.",
                    systemImage: "exclamationmark.triangle"
                ).foregroundStyle(.orange)
            }
            ForEach(AgentConnector.App.allCases) { app in
                HStack {
                    Text(app.name)
                    Spacer()
                    switch statuses[app] ?? .notInstalled {
                    case .connected:
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button("Disconnect") {
                            try? AgentConnector.disconnect(app); refresh()
                        }
                    case .notConnected:
                        Button("Connect") {
                            do { message = try AgentConnector.connect(app) } catch {
                                message = (error as? PlannerError)?.message ?? error.localizedDescription
                            }
                            refresh()
                        }
                    case .notInstalled:
                        Text("Not installed").foregroundStyle(.secondary)
                        if app == .claudeApp { Link("Get it", destination: URL(string: "https://claude.ai/download")!) }
                    }
                }
            }
            if let message { Text(message).font(.caption) }
        }
        Section("Or use Terminal") {
            HStack {
                Text(AgentConnector.terminalCommand).font(.system(size: 11, design: .monospaced)).textSelection(
                    .enabled
                ).lineLimit(2)
                Spacer()
                Button(copied == "cmd" ? "Copied" : "Copy") { copy(AgentConnector.terminalCommand, "cmd") }
            }
            Text("Scripts can also open perch://add?title=Your%20task").font(.caption).foregroundStyle(.secondary)
        }
        Section("Try one of these") {
            ForEach(AgentConnector.examplePrompts, id: \.self) { p in
                Button {
                    copy(p, p)
                } label: {
                    HStack {
                        Text(p); Spacer(); if copied == p { Text("Copied").foregroundStyle(.secondary) }
                    }
                }.buttonStyle(.plain)
            }
            Text(
                "Click a prompt to copy it and paste it into Claude. Its edits appear in the notch immediately; ⌘Z reverts them."
            ).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
    }

    func refresh() { for a in AgentConnector.App.allCases { statuses[a] = AgentConnector.status(a) } }
    func copy(_ s: String, _ tag: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        copied = tag
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == tag { copied = nil } }
    }
}
