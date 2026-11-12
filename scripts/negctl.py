# Scratch-only: break page controls inside the probe's private build copy. Never merged.
import pathlib, sys
root = pathlib.Path(sys.argv[1])
def sub(path, old, new):
    p = root / path; s = p.read_text(); assert old in s, (path, old[:60]); p.write_text(s.replace(old, new, 1))
sub('Sources/PerchApp/Settings/ShortcutPreferenceRow.swift','                if let problem {','                if let problem, false {')
sub('Sources/PerchApp/Settings/SettingsView.swift','AppL10n.format("%lld min", store.prefs.defaultFocusMinutes)','AppL10n.format("%lld min", store.prefs.defaultFocusMinutes + 5)')
sub('Sources/PerchApp/Settings/AgentsSettings.swift','            if !AppInfo.isInApplications {','            if !AppInfo.isInApplications && false {')
sub('Sources/PerchApp/Services/ReminderSyncStatus.swift','            if let error = sync.lastError {','            if let error = sync.lastError, false {')
sub('Sources/PerchApp/Settings/ProjectsList.swift','                            store.apply { try $0.deleteProject(p.id) }','                            _ = p')
sub('Sources/PerchApp/Settings/HistoryList.swift','.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }','.filter { _ in true }')
sub('Sources/PerchApp/Settings/WelcomeView.swift','                .keyboardShortcut(.defaultAction)\n','')
sub('Sources/PerchApp/Workspace/TaskDetailsSheet.swift','"Earlier days are read-only. Your history and focus time stay unchanged."','"History"')
sub('Sources/PerchApp/Workspace/TaskDetailsSheet.swift','description: Text("This task was removed.")','description: Text("")')
sub('Sources/PerchApp/Workspace/TaskDetailsSheet.swift','                if let saveError {','                if let saveError, false {')
sub('Sources/Perch/main.swift','''    case .workspace:
        let lock = MatrixStorageLock(fixture.file)''','''    case .workspace:
        let lock = MatrixStorageLock(fixture.file)
        lock.release()''')
print("negative controls applied: 11")
