import AppKit
import PlannerCore
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
            .font(Theme.meta).foregroundStyle(Theme.secondary)
            if !AppInfo.isInApplications {
                Label(
                    "Agent setup requires Perch to be installed in Applications.",
                    systemImage: "exclamationmark.triangle"
                ).foregroundStyle(Theme.warning)
            }
            ForEach(AgentConnector.App.allCases) { app in
                HStack {
                    Text(app.name)
                    Spacer()
                    switch statuses[app] ?? .notInstalled {
                    case .connected:
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
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
                        Text("Not installed").foregroundStyle(Theme.secondary)
                        if app == .claudeApp { Link("Get it", destination: URL(string: "https://claude.ai/download")!) }
                    }
                }
            }
            if let message { Text(AppL10n.text(message)).font(Theme.meta) }
        }
        Section("Or use Terminal") {
            HStack {
                Text(AgentConnector.terminalCommand).font(Theme.meta.monospaced()).textSelection(
                    .enabled
                ).lineLimit(2)
                Spacer()
                Button(copied == "cmd" ? "Copied" : "Copy") { copy(AgentConnector.terminalCommand, "cmd") }
            }
            Text("Scripts can also open perch://add?title=Your%20task").font(Theme.meta).foregroundStyle(
                Theme.secondary)
        }
        Section("Try one of these") {
            ForEach(AgentConnector.examplePrompts, id: \.self) { p in
                Button {
                    copy(p, p)
                } label: {
                    HStack {
                        Text(AppL10n.text(p)); Spacer();
                        if copied == p { Text("Copied").foregroundStyle(Theme.secondary) }
                    }
                }.buttonStyle(PillStyle())
            }
            Text(
                "Click a prompt to copy it and paste it into Claude. Its edits appear in the notch immediately; ⌘Z reverts them."
            ).font(Theme.meta).foregroundStyle(Theme.secondary)
        }
        .onAppear(perform: refresh)
        .task(id: copied) {
            guard copied != nil else { return }
            do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
            if !Task.isCancelled { copied = nil }
        }
    }

    func refresh() { for a in AgentConnector.App.allCases { statuses[a] = AgentConnector.status(a) } }
    func copy(_ s: String, _ tag: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        copied = tag
    }
}
