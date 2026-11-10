#!/usr/bin/env bash
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
cat > "$PROBE/Sources/Perch/App/main.swift" <<'SWIFT'
import AppKit
import PlannerCore
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

@MainActor
func checkRecovery() async throws {
    guard let path = ProcessInfo.processInfo.environment["PERCH_DATA"],
          let output = ProcessInfo.processInfo.environment["RECOVERY_OUTPUT"] else {
        throw PlannerError("An isolated data path and output directory are required.")
    }
    let url = URL(fileURLWithPath: path)
    let file = PlannerFile(url: url)
    let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    var healthy = Planner()
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    healthy.tasks = [PlanTask(id: id, title: "Recovery fixture", day: nil, createdAt: fixedNow)]
    healthy.preferences.welcomeCompleted = true
    healthy.preferences.catchCopies = false
    healthy.preferences.catchScreenshots = false
    let raw = try damage(healthy)
    try raw.write(to: url)
    let store = PlannerStore(file: file, now: { fixedNow }, watching: false)
    require(store.planner == healthy, "startup displays all valid records from a damaged collection")
    require(store.lastError?.contains("read-only") == true, "startup exposes a read-only recovery warning")
    require(store.lastError?.contains("original planner is unchanged") == true, "warning explains original preservation")
    require(store.lastError?.contains("Do not replace the original") == true, "warning explains draft omission risk")
    require(!store.canUndo && !store.canRedo, "startup recovery adds no undo or redo entries")
    let original = try Data(contentsOf: url)
    require(original == raw, "startup leaves the original byte-for-byte unchanged")
    let files = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
    let copies = files.filter { $0.lastPathComponent.contains(".corrupt-") && !$0.lastPathComponent.contains(".recovered.") && !$0.lastPathComponent.contains(".issues.") }
    require(copies.count == 1, "one lossless quarantine is available")
    let quarantined = try Data(contentsOf: copies[0])
    require(quarantined == raw, "quarantine contains the exact original bytes")
    var bodyRan = false
    for _ in 0..<3 {
        store.reloadFromDisk(external: true)
        let changed: Bool? = store.apply { engine in
            bodyRan = true
            engine.planner.tasks.removeAll()
            return true
        }
        require(changed == nil && !bodyRan && store.planner == healthy, "recovered records reject mutation without running the edit")
        let bytes = try Data(contentsOf: url)
        require(bytes == raw, "reload and attempted save never persist the reduced list")
    }
    let afterFiles = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    require(afterFiles.count == files.count, "identical failed reloads and saves create no recovery-file churn")

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
    try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("recovery-banner.png"))
    require(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "real error banner renders in a native hosting view")
    window.close()

    // Repair with the same valid records. Even an equal planner must clear the warning.
    try encode(healthy).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: fixedNow], ofItemAtPath: url.path)
    store.reloadFromDisk(external: true)
    require(store.lastError == nil && store.planner == healthy, "repair with unchanged valid records clears the recovery warning")
    store.updateTask(id) { $0.notes = "Local edit" }
    require(store.canUndo, "editing resumes only after the document is repaired")
    let edited = store.planner
    var externallyChanged = edited
    externallyChanged.tasks[0].reminderLink = "synthetic-link"
    externallyChanged.tasks[0].priority = .high
    let nextRaw = try damage(externallyChanged)
    try nextRaw.write(to: url)
    try FileManager.default.setAttributes([.modificationDate: fixedNow.addingTimeInterval(1)], ofItemAtPath: url.path)
    store.reloadFromDisk(external: true)
    require(store.planner == externallyChanged && store.lastError != nil, "reload displays newly recovered records instead of stale state")
    require(store.canUndo, "recovery reload preserves local undo history")
    store.undo()
    require(store.planner == externallyChanged && store.canUndo, "undo fails closed while the file needs recovery")
    try encode(externallyChanged).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: fixedNow.addingTimeInterval(2)], ofItemAtPath: url.path)
    store.reloadFromDisk(external: true)
    store.undo()
    require(store.planner.tasks[0].notes == "" && store.planner.tasks[0].reminderLink == "synthetic-link" && store.planner.tasks[0].priority == .high,
            "repair retains field-scoped undo and external sync bookkeeping")
    require(store.planner.focus == nil, "recovery and undo do not create a timer")

    // An unreadable file must retain the visible state, then retry after a permission-only repair.
    let beforeUnreadable = store.planner
    let permissionBytes = try Data(contentsOf: url)
    let modification = file.modificationDate!
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    let denied = PlannerStore(file: file, now: { fixedNow }, watching: false)
    require(denied.lastError?.contains("Unable to read") == true, "unreadable startup is not silently treated as empty data")
    try FileManager.default.setAttributes([.modificationDate: modification.addingTimeInterval(1)], ofItemAtPath: url.path)
    store.reloadFromDisk(external: true)
    require(store.planner == beforeUnreadable && store.lastError != nil, "unreadable reload preserves the visible document")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    denied.reloadFromDisk(external: true)
    store.reloadFromDisk(external: true)
    require(denied.planner == beforeUnreadable && denied.lastError == nil && store.lastError == nil,
            "access repair retries even without a content modification")
    let afterPermissionBytes = try Data(contentsOf: url)
    require(afterPermissionBytes == permissionBytes, "permission failures never rewrite planner data")

    let future = Data(#"{"version":999,"tasks":[{}]}"#.utf8)
    try future.write(to: url)
    let newer = PlannerStore(file: file, watching: false)
    require(newer.lastError?.contains("not supported") == true, "newer schemas expose an explicit compatibility error")
    let futureBytes = try Data(contentsOf: url)
    require(futureBytes == future, "newer schemas remain untouched at startup")
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
swift build --package-path "$PROBE" -j 2 -c release --product Perch
DATA=$(mktemp -d "$OUT/data.XXXXXX")
PERCH_DATA="$DATA/planner.json" RECOVERY_OUTPUT="$OUT" "$PROBE/.build/release/Perch"
