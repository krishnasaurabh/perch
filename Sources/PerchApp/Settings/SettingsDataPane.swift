import AppKit
import SwiftUI

/// Storage and export entry points remain available during the data-pane build.
struct SettingsDataPane: View {
    @EnvironmentObject var store: PlannerStore
    @ObservedObject var feedback: SettingsFailureFeedback

    var body: some View {
        SettingsSection("Where it lives") {
            SettingsRow("On this Mac only") {
                PerchButton("Show in Finder", kind: .soft, size: .small) {
                    NSWorkspace.shared.activateFileViewerSelecting([store.file.url])
                }
            }
            Text(store.file.url.path)
                .perchFont(.detail)
                .foregroundStyle(Theme.ink2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                "Perch stores your planner on this Mac and has no analytics. Optional Reminders sync uses your configured Reminders account. Connected AI apps can read and edit the planner."
            )
            .perchFont(.detail)
            .foregroundStyle(Theme.ink2)
            .fixedSize(horizontal: false, vertical: true)
        }
        SettingsSection("Take it with you") {
            SettingsRow("Export everything") {
                PerchButton("Export", kind: .soft, size: .small, action: exportBackup)
            }
        }
        SettingsSection("About") {
            SettingsRow(AppL10n.text("Version")) { Text(AppInfo.version).perchFont(.detail) }
            PerchButton("Quit Perch", kind: .quiet, size: .small) { NSApp.terminate(nil) }
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Perch-\(store.today).json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            feedback.exportBackup(to: url, store: store)
        }
    }
}
