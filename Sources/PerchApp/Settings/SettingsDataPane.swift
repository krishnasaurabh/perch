import AppKit
import PlannerCore
import SwiftUI

struct SettingsDataPane: View {
    @EnvironmentObject var store: PlannerStore
    @ObservedObject var feedback: SettingsFailureFeedback
    var actions = SettingsDataActions()

    private var backups: SettingsDataBackupStatus { SettingsDataBackupStatus(file: store.file) }
    private var storageLocation: String {
        let directory = store.file.url.deletingLastPathComponent()
        return "\(directory.deletingLastPathComponent().lastPathComponent) › \(directory.lastPathComponent)"
    }

    var body: some View {
        SettingsSection("Where it lives") {
            SettingsRow("On this Mac only") {
                HStack(spacing: SurfaceMetrics.compactGap) {
                    PerchPill(storageLocation)
                        .help(store.file.url.deletingLastPathComponent().path)
                        .accessibilityValue(store.file.url.deletingLastPathComponent().path)
                    PerchButton("Show in Finder", kind: .quiet, size: .small) {
                        actions.showInFinder(store: store)
                    }
                    .accessibilityIdentifier("settings.data.finder")
                }
            }
            SettingsRow("Backups") {
                HStack(spacing: SurfaceMetrics.compactGap) {
                    PerchPill(SettingsDataBackupStatus.policy)
                    PerchButton("Restore", kind: .quiet, size: .small) {
                        actions.restoreBackup(store: store, feedback: feedback)
                    }
                    .disabled(!backups.canRestore)
                    .accessibilityIdentifier("settings.data.restore")
                }
            }
            SettingsRow("Last backup") {
                Text(backups.label)
                    .perchFont(.detail)
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.data.lastBackup")
            }
        }
        SettingsSection("Take it with you") {
            SettingsRow("Export everything") {
                PerchButton("Export", kind: .soft, size: .small) {
                    actions.exportEverything(store: store, feedback: feedback)
                }
                .accessibilityIdentifier("settings.data.export")
            }
            SettingsRow(
                "Bring tasks in from a file", help: AppL10n.text("Exports are plain files you can open anywhere.")
            ) {
                PerchButton("Import", kind: .soft, size: .small) {
                    actions.importTasks(store: store)
                }
                .accessibilityIdentifier("settings.data.import")
            }
        }
        SettingsSection("Tidy up") {
            SettingsRow("Clear finished tasks older than") {
                PerchSegmented(
                    title: "Clear finished tasks older than",
                    items: [(.never, "Never"), (.thirtyDays, "30 days"), (.ninetyDays, "90 days")],
                    selection: Binding(
                        get: { store.prefs.finishedTaskRetention },
                        set: { actions.setRetention($0, store: store) }))
            }
            SettingsRow("Empty the parking lot") {
                PerchButton("Empty", kind: .soft, size: .small) {
                    actions.emptyParkingLot(store: store)
                }
                .disabled(store.planner.parkedThoughts.isEmpty)
                .accessibilityIdentifier("settings.data.empty")
            }
            SettingsRow("Erase everything on this Mac") {
                PerchButton("Erase", kind: .quiet, size: .small) {
                    actions.eraseEverything(store: store)
                }
                .accessibilityIdentifier("settings.data.erase")
            }
        }
    }
}

/// File dialogs and confirmation are injectable; all mutations use the store's command gateway.
@MainActor
struct SettingsDataActions {
    var confirm: (SettingsDataConfirmation) -> Bool = { request in
        alert(for: request).runModal() == .alertSecondButtonReturn
    }
    var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    var chooseExport: (String) -> URL? = { name in
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.json]
        return panel.runModal() == .OK ? panel.url : nil
    }
    var chooseImport: () -> URL? = {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func showInFinder(store: PlannerStore) { reveal(store.file.url) }

    func exportEverything(store: PlannerStore, feedback: SettingsFailureFeedback) {
        guard let url = chooseExport("Perch-\(store.today).json"), store.flushPendingText() else { return }
        feedback.exportBackup(to: url, store: store)
    }

    func importTasks(store: PlannerStore) {
        guard let url = chooseImport() else { return }
        store.apply { commands in try commands.importTasks(from: Data(contentsOf: url)) }
    }

    func setRetention(_ value: FinishedTaskRetention, store: PlannerStore) {
        guard value != store.prefs.finishedTaskRetention else { return }
        guard value == .never || confirm(.retention(value)) else { return }
        store.apply { try $0.updatePreference(.finishedTaskRetention(value)) }
    }

    func emptyParkingLot(store: PlannerStore) {
        guard confirm(.emptyParkingLot) else { return }
        store.send(.emptyParkingLot)
    }

    func eraseEverything(store: PlannerStore) {
        guard confirm(.eraseEverything) else { return }
        store.send(.eraseLocalPlanner)
    }

    func restoreBackup(store: PlannerStore, feedback: SettingsFailureFeedback) {
        guard confirm(.restoreBackup) else { return }
        guard store.flushPendingText() else { return }
        feedback.perform(store: store, failure: { .planner($0.perchPresentationDetail) }) {
            try store.restoreLatestBackup()
        }
    }

    static func alert(for request: SettingsDataConfirmation) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.title
        alert.informativeText = request.detail
        // Return and Escape both cancel; the destructive action requires an explicit choice.
        let cancel = alert.addButton(withTitle: AppL10n.text("Cancel"))
        cancel.keyEquivalent = "\u{1b}"
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        let proceed = alert.addButton(withTitle: request.actionTitle)
        proceed.keyEquivalent = ""
        return alert
    }
}

enum SettingsDataConfirmation: Equatable {
    case retention(FinishedTaskRetention), emptyParkingLot, eraseEverything, restoreBackup

    var title: String {
        switch self {
        case .retention: AppL10n.text("Clear older finished tasks?")
        case .emptyParkingLot: AppL10n.text("Empty the parking lot?")
        case .eraseEverything: AppL10n.text("Erase everything on this Mac?")
        case .restoreBackup: AppL10n.text("Restore the latest readable backup?")
        }
    }

    var detail: String {
        switch self {
        case .retention(let value):
            AppL10n.format(
                "Finished tasks older than %lld days will be cleared now and on each new day. Open tasks stay. You can undo this change while Perch is open.",
                Int64(value.rawValue))
        case .emptyParkingLot:
            AppL10n.text("Parked thoughts will be cleared. Tasks stay. You can undo this change while Perch is open.")
        case .eraseEverything:
            AppL10n.text(
                "Planner data will be cleared and settings reset. Recovery backups and connected apps are kept. You can undo this change while Perch is open."
            )
        case .restoreBackup:
            AppL10n.text(
                "The latest readable backup will replace your planner. Your current planner is backed up first. Settings stay."
            )
        }
    }

    var actionTitle: String {
        switch self {
        case .retention: AppL10n.text("Clear finished tasks")
        case .emptyParkingLot: AppL10n.text("Empty")
        case .eraseEverything: AppL10n.text("Erase")
        case .restoreBackup: AppL10n.text("Restore")
        }
    }
}

struct SettingsDataBackupStatus {
    let lastBackup: Date?
    let canRestore: Bool
    let unavailable: Bool

    static var policy: String {
        AppL10n.format("Before changes, %lld copies", Int64(PlannerFile.backupLimit))
    }

    init(file: PlannerFile) {
        do {
            let urls = try file.backupURLs()
            let date = try urls.first?.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            canRestore = !urls.isEmpty
            lastBackup = date
            unavailable = false
        } catch {
            canRestore = false
            lastBackup = nil
            unavailable = true
        }
    }

    var label: String {
        if unavailable { return AppL10n.text("Backup information unavailable") }
        guard let lastBackup else { return AppL10n.text("No backups yet") }
        return lastBackup.formatted(date: .abbreviated, time: .shortened)
    }
}
