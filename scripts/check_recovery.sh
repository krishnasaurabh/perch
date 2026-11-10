#!/usr/bin/env bash
# macOS-only: drives the real Perch target against a synthetic PERCH_DATA to prove a damaged
# planner stays visible read-only, its bytes and quarantine survive, and nothing is rewritten.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || exit 2
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?output directory required}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
PROBE=$(mktemp -d "$OUT/build.XXXXXX")
trap 'rm -rf "$PROBE"' EXIT
cp "$ROOT/Package.swift" "$PROBE/"
cp -R "$ROOT/Sources" "$ROOT/Tests" "$PROBE/"
cat > "$PROBE/Sources/Perch/main.swift" <<'SWIFT'
import AppKit
import Darwin
@testable import PlannerCore
#if canImport(PerchApp)
@testable import PerchApp
import PerchUI
import PerchMCP
#endif
import SwiftUI

@MainActor
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}

func encode(_ planner: Planner) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(planner)
}

/// Seeds a valid planner plus two rejected records: a task with an unknown priority and a
/// task missing its required id. Everything else in the document stays valid.
func damage(_ planner: Planner) throws -> Data {
    var object = try JSONSerialization.jsonObject(with: encode(planner)) as! [String: Any]
    var tasks = object["tasks"] as! [[String: Any]]
    var broken = tasks[0]
    broken["priority"] = "unrecognized-value"
    tasks.insert(broken, at: 0)
    tasks.append(["title": "Missing required fields"])
    object["tasks"] = tasks
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
}

func contents(_ url: URL) throws -> Data { try Data(contentsOf: url) }

func listing(_ url: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).sorted()
}

func touch(_ url: URL, _ date: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

@MainActor
func recovery(of file: PlannerFile) throws -> PlannerRecoveryError {
    do {
        _ = try file.load()
    } catch let error as PlannerRecoveryError {
        return error
    }
    throw PlannerError("Expected a recoverable planner document.")
}

@MainActor
func checkRecovery() async throws {
    guard let path = ProcessInfo.processInfo.environment["PERCH_DATA"],
          let output = ProcessInfo.processInfo.environment["RECOVERY_OUTPUT"] else {
        throw PlannerError("An isolated data path and output directory are required.")
    }
    let url = URL(fileURLWithPath: path)
    let outputURL = URL(fileURLWithPath: output)
    let file = PlannerFile(url: url)
    let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    let today = PlannerEngine(planner: Planner(), now: { fixedNow }).today
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let repeatID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    var healthy = Planner()
    healthy.tasks = [
        PlanTask(id: id, title: "Recovery fixture", day: nil, createdAt: fixedNow),
        PlanTask(id: repeatID, title: "Repeat fixture", day: today, createdAt: fixedNow, repeatRule: .daily),
    ]
    healthy.preferences.welcomeCompleted = true
    healthy.preferences.catchCopies = false
    healthy.preferences.catchScreenshots = false
    let raw = try damage(healthy)
    try raw.write(to: url)

    // Read the typed contract first, so the store is compared against it rather than
    // against message literals copied into the probe.
    let typed = try recovery(of: file)
    require(typed.keptCount == 2 && typed.quarantinedCount == 2 && typed.quarantinedFieldCount == 0,
            "fixture keeps two valid records and quarantines two invalid ones")
    require(typed.issues.map(\.path) == ["tasks[0].priority", "tasks[3].id"],
            "rejected locations address the unchanged original JSON")
    require(typed.quarantineURL == typed.originalURL, "quarantine URL names the exact original copy")

    let store = PlannerStore(file: file, now: { fixedNow }, watching: false)
    require(store.planner == healthy, "startup displays every valid record")
    require(store.planner.tasks.map(\.title) == ["Recovery fixture", "Repeat fixture"], "valid records are visible in order")
    require(store.lastError == typed.localizedDescription, "startup surfaces the exact typed recovery text")
    let text = store.lastError ?? ""
    require(text.contains("Kept 2 valid record(s) in a read-only draft"), "warning reports the exact kept count")
    require(text.contains("Quarantined 2 invalid record(s) and 0 invalid field(s)"), "warning reports the exact quarantined counts")
    require(text.contains("read-only") && text.contains("original planner is unchanged"), "warning states the records are read-only and preserved")
    require(text.contains(typed.quarantineURL.path) && text.contains(typed.recoveredURL.path) && text.contains(typed.issuesURL.path),
            "warning names all three recovery artifacts")
    require(text.contains("Do not replace the original"), "warning explains draft omission risk")
    require(!store.canUndo && !store.canRedo, "startup recovery adds no undo or redo entries")
    let startedBytes = try contents(url)
    require(startedBytes == raw, "startup leaves the original byte-for-byte unchanged")
    try text.write(to: outputURL.appendingPathComponent("recovery-text.txt"), atomically: true, encoding: .utf8)

    let started = try listing(url)
    let copies = started.filter { $0.contains(".corrupt-") && !$0.contains(".recovered.") && !$0.contains(".issues.") }
    require(copies.count == 1, "exactly one quarantine copy exists")
    let quarantinedBytes = try contents(url.deletingLastPathComponent().appendingPathComponent(copies[0]))
    require(quarantinedBytes == raw, "quarantine holds the malformed raw records losslessly")
    let typedQuarantineBytes = try contents(typed.quarantineURL)
    require(typedQuarantineBytes == raw, "the typed quarantine path is that lossless copy")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let draftPlanner = try decoder.decode(Planner.self, from: try contents(typed.recoveredURL))
    require(draftPlanner == healthy, "the recovered draft holds only the valid records")
    let listedIssues = try decoder.decode([PlannerRecoveryIssue].self, from: try contents(typed.issuesURL))
    require(listedIssues == typed.issues, "the issues sidecar lists exactly the quarantined locations")
    require(!FileManager.default.fileExists(atPath: file.backupDirectory.path), "no automatic backup revision was written")

    // Every persistence entry point must refuse before the edit body runs.
    func refuse(_ label: String, _ edit: (PlannerCommands) throws -> Void) throws {
        var ran = false
        let refused: Bool? = store.apply { engine in
            ran = true
            try edit(engine)
            return true
        }
        let unchanged = try contents(url) == raw
        require(refused == nil && !ran, label + ": refused before the edit runs")
        require(store.planner == healthy, label + ": valid records stay unchanged")
        require(store.lastError == typed.localizedDescription, label + ": exact recovery text stays surfaced")
        require(unchanged, label + ": original stays byte-identical")
    }

    func untouched(_ label: String) throws {
        let unchanged = try contents(url) == raw
        require(store.planner == healthy, label + ": valid records stay unchanged")
        require(store.lastError == typed.localizedDescription, label + ": exact recovery text stays surfaced")
        require(unchanged, label + ": original stays byte-identical")
    }

    try refuse("tracked task edit") { engine in _ = try engine.addTasks(["Refused"]) }
    try refuse("preference change") { engine in try engine.updatePrefs { $0.resetHour = 5 } }

    var syncRan = false
    store.updateTask(id) { task in
        syncRan = true
        task.reminderLink = "synthetic-link"
    }
    require(!syncRan && store.planner.tasks[0].reminderLink == nil, "synthetic sync-link update is refused")
    try untouched("synthetic sync-link update")

    let ticked: Bool? = store.applyUntracked { try $0.tick() }
    require(ticked == nil, "timer tick checkpoint write is refused")
    try untouched("timer tick checkpoint")

    let resumed: Bool? = store.applyUntracked { try $0.recoverFocus() }
    require(resumed == nil, "launch timer recovery write is refused")
    try untouched("launch timer recovery")

    let tomorrow = store.dayKey(fixedNow.addingTimeInterval(86_400))
    store.materializeRepeats(on: [tomorrow])
    let repeatBytes = try contents(url)
    require(store.planner == healthy && repeatBytes == raw, "repeat materialization cannot save a reduced list")
    require(store.lastError == typed.localizedDescription, "repeat materialization keeps the exact recovery text")

    store.setText("Recovered draft edit", for: .title(id))
    try await Task.sleep(nanoseconds: 700_000_000)
    require(store.text(for: .title(id)) == "Recovered draft edit", "failed debounced autosave retains the pending text")
    try untouched("debounced autosave")
    require(store.flushPendingText() == false, "an explicit pending-text flush is refused")
    try untouched("explicit pending-text flush")
    store.setText(healthy.tasks[0].title, for: .title(id))
    require(!store.canUndo, "clearing the retry draft leaves no undo entry")

    var directThrew = false
    do { try file.mutate { $0.tasks.removeAll() } } catch { directThrew = true }
    require(directThrew, "a direct locked mutation is refused")

    var saveError: Error?
    do { try file.save(healthy) } catch { saveError = error }
    require(saveError is PlannerDataError, "a direct save fails closed with a typed storage error")

    let exportURL = outputURL.appendingPathComponent("export.json")
    var exportThrew = false
    do { try file.export(to: exportURL) } catch { exportThrew = true }
    let exportMissing = !FileManager.default.fileExists(atPath: exportURL.path)
    require(exportThrew && exportMissing, "export refuses damaged data and creates no output")
    try untouched("direct save and export")
    require(!FileManager.default.fileExists(atPath: file.backupDirectory.path), "refused writes never snapshot a reduced planner")

    // Repeated reloads of identical damage reuse the same recovery material.
    for step in 0..<3 {
        try touch(url, fixedNow.addingTimeInterval(Double(step + 1)))
        store.reloadFromDisk(external: true)
        require(store.planner == healthy && store.lastError == typed.localizedDescription,
                "reload \(step + 1) keeps the recovered view and the exact text")
        let unchanged = try contents(url) == raw
        require(unchanged, "reload \(step + 1) leaves the original byte-identical")
        let sameFiles = try listing(url) == started
        require(sameFiles, "reload \(step + 1) adds no recovery copies")
    }

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = NSHostingView(rootView: ErrorBanner().environmentObject(store).padding().frame(width: 780, height: 100))
    window.contentView = view
    window.orderFront(nil)
    try await Task.sleep(nanoseconds: 150_000_000)
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw PlannerError("Recovery banner did not render.") }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = bitmap.representation(using: .png, properties: [:])!
    try png.write(to: outputURL.appendingPathComponent("recovery-banner.png"))
    require(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "real error banner renders in a native hosting view")
    window.close()

    // Repair with the same valid records. Even an equal planner must clear the warning.
    try encode(healthy).write(to: url)
    try touch(url, fixedNow.addingTimeInterval(10))
    store.reloadFromDisk(external: true)
    require(store.lastError == nil && store.planner == healthy, "repair with unchanged valid records clears the recovery warning")
    let keptMaterial = try listing(url) == started
    require(keptMaterial, "repair keeps the quarantine material for the user")
    store.updateTask(id) { $0.notes = "Local edit" }
    require(store.canUndo && store.planner.tasks[0].notes == "Local edit", "editing resumes only after the document is repaired")

    var externallyChanged = store.planner
    externallyChanged.tasks[0].reminderLink = "synthetic-link"
    externallyChanged.tasks[0].priority = .high
    let nextRaw = try damage(externallyChanged)
    try nextRaw.write(to: url)
    try touch(url, fixedNow.addingTimeInterval(11))
    store.reloadFromDisk(external: true)
    require(store.planner == externallyChanged && store.lastError != nil, "reload displays newly recovered records instead of stale state")
    let reloaded = try recovery(of: file)
    require(store.lastError == reloaded.localizedDescription, "reload surfaces the exact typed text for the new damage")
    require(store.canUndo, "recovery reload preserves local undo history")
    let beforeUndo = try contents(url)
    store.undo()
    require(store.planner == externallyChanged && store.canUndo, "undo fails closed while the file needs recovery")
    require(beforeUndo == nextRaw, "failed undo leaves the original unchanged")
    try encode(externallyChanged).write(to: url)
    try touch(url, fixedNow.addingTimeInterval(12))
    store.reloadFromDisk(external: true)
    store.undo()
    require(store.planner.tasks[0].notes == "" && store.planner.tasks[0].reminderLink == "synthetic-link" && store.planner.tasks[0].priority == .high,
            "repair retains field-scoped undo and external sync bookkeeping")
    require(store.planner.focus == nil, "recovery and undo do not create a timer")

    // An unreadable file must retain the visible state, then retry after a permission-only repair.
    // Root ignores file modes, so only assert this as an ordinary user.
    if geteuid() != 0 {
        let beforeUnreadable = store.planner
        let permissionBytes = try contents(url)
        let modification = file.modificationDate ?? fixedNow
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        let denied = PlannerStore(file: file, now: { fixedNow }, watching: false)
        let deniedText = denied.lastError ?? ""
        require(deniedText.hasPrefix("Unable to read planner data at " + url.path), "unreadable startup is not silently treated as empty data")
        require(deniedText.contains("check file access before retrying"), "unreadable startup explains the retry")
        try touch(url, modification.addingTimeInterval(1))
        store.reloadFromDisk(external: true)
        require(store.planner == beforeUnreadable && store.lastError != nil, "unreadable reload preserves the visible document")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        denied.reloadFromDisk(external: true)
        store.reloadFromDisk(external: true)
        require(denied.planner == beforeUnreadable && denied.lastError == nil && store.lastError == nil,
                "access repair retries even without a content modification")
        let permissionUnchanged = try contents(url) == permissionBytes
        require(permissionUnchanged, "permission failures never rewrite planner data")
    } else {
        print("SKIP: permission checks need a non-root user")
    }

    // A newer schema fails closed: an exact compatibility error, no draft, no rewrite.
    let beforeFuture = try listing(url)
    let future = Data(#"{"version":999,"tasks":[{}]}"#.utf8)
    try future.write(to: url)
    var schemaError: PlannerSchemaError?
    do { _ = try file.load() } catch let error as PlannerSchemaError { schemaError = error } catch {}
    require(schemaError != nil && schemaError?.version == 999, "a newer schema raises the typed compatibility error")
    let newer = PlannerStore(file: file, watching: false)
    require(newer.lastError == schemaError?.localizedDescription, "a newer schema surfaces the exact compatibility error")
    require(newer.planner == Planner() && newer.planner.tasks.isEmpty, "a newer schema never displays a partial document")
    let futureBytes = try contents(url)
    require(futureBytes == future, "a newer schema remains untouched at startup")
    let futureFiles = try listing(url)
    require(futureFiles == beforeFuture, "a newer schema is never quarantined or rewritten")
    let futureEdit: Bool? = newer.apply { engine in
        _ = try engine.addTasks(["Refused"], on: .inbox)
        return true
    }
    require(futureEdit == nil, "a newer schema refuses edits")
    require(newer.lastError == schemaError?.localizedDescription, "a newer schema keeps the exact compatibility error")
    let afterRefusedEdit = try contents(url)
    require(afterRefusedEdit == future, "a refused edit never rewrites a newer schema")
    print("Recovery app probe passed")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    do { try await checkRecovery(); exit(0) }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
app.run()
SWIFT
swift build -Xswiftc -enable-testing --package-path "$PROBE" -j 2 -c release --product Perch
DATA=$(mktemp -d "$OUT/data.XXXXXX")
PERCH_DATA="$DATA/planner.json" RECOVERY_OUTPUT="$OUT" "$PROBE/.build/release/Perch"
