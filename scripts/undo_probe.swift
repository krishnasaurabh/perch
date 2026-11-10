import AppKit
import PlannerCore
import SwiftUI

@MainActor
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}

@MainActor
final class ProbeClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: Double) { now.addTimeInterval(seconds) }
}

@MainActor
func checkStore() throws -> PlannerStore {
    let clock = ProbeClock()
    let store = PlannerStore(now: { clock.now }, watching: false)
    let task = store.apply { try $0.addTasks(["Undo fixture"], on: .day($0.today)) }![0]
    store.apply { try $0.startTimer(task: task.id.uuidString, minutes: 5) }
    store.updateTask(task.id) { $0.title = "Edited fixture" }
    clock.advance(30.25)
    store.apply { try $0.pauseTimer() }
    let paused = store.planner.focus
    clock.advance(600)
    store.undo()
    require(store.planner.focus == paused, "Undo must not resume a paused timer")
    require(store.planner.tasks.first?.title == "Undo fixture", "timer actions must not consume user edit history")
    require(store.planner.tasks.first?.focusedSeconds == 30.25, "undo preserves credited focus")
    store.redo()
    require(store.planner.focus == paused, "Redo must not resume a paused timer")
    require(store.planner.tasks.first?.title == "Edited fixture", "Redo restores only the user edit")
    store.apply { try $0.resumeTimer() }
    clock.advance(4.75)
    store.apply { _ = $0.stopTimer() }
    store.undo(); store.redo()
    require(
        store.planner.focus == nil && store.planner.tasks[0].focusedSeconds == 35,
        "stop remains stopped with no paused-time credit")

    store.apply { try $0.startTimer(task: task.id.uuidString, minutes: 1) }
    clock.advance(5)
    store.apply { _ = try $0.complete(task.id.uuidString) }
    store.undo()
    require(
        !store.planner.tasks[0].done && store.planner.focus?.state != .running,
        "undo completion reopens task without restarting timer")
    store.redo()
    require(
        store.planner.tasks[0].done && store.planner.tasks[0].focusedSeconds == 40,
        "redo completion keeps exact focus credit")

    store.updateTask(task.id) { $0.notes = "Local note" }
    try store.file.mutate {
        $0.tasks[0].reminderLink = "synthetic-link"
        $0.tasks[0].priority = .high
        $0.tasks.append(PlanTask(title: "External fixture", day: nil))
    }
    // Deliberately do not reload: undo must read the current locked document, not the view.
    store.undo()
    require(store.planner.tasks[0].notes == "", "undo reads the current disk document")
    require(
        store.planner.tasks[0].priority == .high && store.planner.tasks.count == 2,
        "undo preserves unrelated external edits")
    require(store.planner.tasks[0].reminderLink == "synthetic-link", "undo preserves sync identifiers")
    try store.file.mutate { $0.tasks[0].reminderLink = "synthetic-link-2" }
    store.reloadFromDisk(external: true)
    store.redo()
    require(
        store.planner.tasks[0].notes == "Local note" && store.planner.tasks[0].reminderLink == "synthetic-link-2",
        "external link reload preserves redo")
    store.apply { $0.planner.tasks[0].reminderLink = "synthetic-link-3" }
    store.undo()
    require(
        store.planner.tasks[0].notes == "" && store.planner.tasks[0].reminderLink == "synthetic-link-3",
        "link-only apply never consumes Cmd-Z")
    store.redo()

    let directory = store.file.url.deletingLastPathComponent()
    let originalPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]!
    @MainActor func readOnly(_ yes: Bool) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: yes ? NSNumber(value: 0o555) : originalPermissions], ofItemAtPath: directory.path)
    }
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: directory.path)
    }
    let beforeFailure = store.planner
    try readOnly(true)
    store.undo()
    require(
        store.lastError != nil && store.planner == beforeFailure && store.canUndo && !store.canRedo,
        "failed undo keeps visible state and both stacks")
    try readOnly(false)
    store.undo()
    let undone = store.planner
    try readOnly(true)
    store.redo()
    require(store.lastError != nil && store.planner == undone && store.canRedo, "failed redo is retryable")
    try readOnly(false)
    store.redo()
    require(store.planner == beforeFailure && store.lastError == nil, "redo retry succeeds")

    try readOnly(true)
    store.updateTask(task.id) { $0.notes = "Must not persist" }
    require(store.planner == beforeFailure && store.lastError != nil, "failed edit does not publish unpersisted state")
    try readOnly(false)

    let title = PlannerStore.TextTarget.title(task.id)
    let notes = PlannerStore.TextTarget.notes(task.id)
    let notepad = PlannerStore.TextTarget.notepad(store.today)
    store.setText("F", for: title); store.setText("Final draft title", for: title)
    store.setText("N", for: notes); store.setText("Final draft notes", for: notes)
    store.setText("P", for: notepad); store.setText("Final draft notepad", for: notepad)
    let beforeFlush = try store.file.load()
    require(beforeFlush == beforeFailure, "typing performs no per-keystroke writes")
    try readOnly(true)
    let delegate = AppDelegate()
    delegate.store = store
    require(
        delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "failed draft persistence cancels termination")
    require(
        store.text(for: title) == "Final draft title" && store.text(for: notepad) == "Final draft notepad",
        "failed save retains drafts outside the view")
    try readOnly(false)
    require(delegate.applicationShouldTerminate(NSApp) == .terminateNow, "termination flushes pending text")
    let saved = try store.file.load()
    require(
        saved.tasks[0].title == "Final draft title" && saved.tasks[0].notes == "Final draft notes",
        "title and notes persist on close")
    require(saved.notes.first?.text == "Final draft notepad", "notepad persists on close")
    store.undo()
    require(
        store.planner.tasks[0].title == beforeFailure.tasks[0].title && store.planner.notes.isEmpty,
        "one undo removes a typing burst")
    store.redo()
    require(store.planner.tasks[0].title == "Final draft title", "one redo restores a typing burst")

    store.setText("Retained conflict draft", for: notes)
    try store.file.mutate { $0.tasks[0].notes = "External concurrent note" }
    require(!store.flushPendingText(), "concurrent same-field text edit is not overwritten")
    let conflict = try store.file.load()
    require(
        conflict.tasks[0].notes == "External concurrent note" && store.text(for: notes) == "Retained conflict draft",
        "external text and local draft both survive conflict")
    try store.file.mutate { $0.tasks[0].notes = "Final draft notes" }
    require(store.flushPendingText(), "retained draft can be retried after conflict resolution")
    return store
}

@MainActor
func checkDeletionRedo() throws {
    let clock = ProbeClock()
    let store = PlannerStore(now: { clock.now }, watching: false)
    let zero = store.apply { try $0.addTasks(["Unfocused deletion fixture"], on: .day($0.today)) }![0]
    store.apply { try $0.delete(zero.id.uuidString, on: .day($0.today)) }
    require(!store.planner.tasks.contains { $0.id == zero.id }, "zero-credit deletion removes task")
    store.undo()
    let zeroRestored = store.planner
    require(store.planner.tasks.first { $0.id == zero.id }?.focusedSeconds == 0, "zero-credit undo restores task")
    store.redo()
    require(!store.planner.tasks.contains { $0.id == zero.id }, "zero-credit redo removes task")
    store.undo()
    require(store.planner == zeroRestored, "zero-credit second undo restores exact content")

    let task = store.apply { try $0.addTasks(["Focused deletion fixture"], on: .day($0.today)) }![0]
    store.apply { try $0.startTimer(task: task.id.uuidString, minutes: 1) }
    clock.advance(30.25)
    store.apply { try $0.pauseTimer() }
    clock.advance(600)
    store.apply { try $0.resumeTimer() }
    clock.advance(29.75)
    store.apply { _ = $0.tick() }
    let ledger = store.planner.focusSegments
    require(
        store.planner.tasks.first { $0.id == task.id }?.focusedSeconds == 60,
        "focused deletion fixture has exact sixty-second credit")
    let segments = ledger.filter { $0.taskID == task.id }
    require(segments.count == 2 && segments[0].end < segments[1].start, "focused deletion fixture excludes paused gap")
    try store.file.mutate { planner in
        let i = planner.tasks.firstIndex { $0.id == task.id }!
        planner.tasks[i].reminderLink = "retired-synthetic-link"
        planner.tasks[i].agentID = "retired-synthetic-caller"
    }
    store.apply { try $0.delete(task.id.uuidString, on: .day($0.today)) }
    require(
        store.lastError == nil && !store.planner.tasks.contains { $0.id == task.id },
        "focused deletion removes task from latest disk state")
    require(
        store.planner.focus == nil && store.planner.focusSegments == ledger,
        "deletion clears timer but retains exact ledger")
    store.undo()
    let restored = store.planner
    let restoredTask = restored.tasks.first { $0.id == task.id }
    require(restoredTask?.focusedSeconds == 60, "focused deletion undo reconstructs exact credit")
    require(
        restoredTask != nil && restoredTask?.reminderLink == nil && restoredTask?.agentID == nil,
        "focused deletion undo excludes stale service identity")
    require(restored.focus == nil && restored.focusSegments == ledger, "focused deletion undo cannot resurrect timer")
    for _ in 0..<2 {
        store.redo()
        let deleted = try store.file.load()
        require(
            !deleted.tasks.contains { $0.id == task.id } && store.planner == deleted,
            "focused deletion redo removes persisted and visible task")
        require(
            deleted.focus == nil && deleted.focusSegments == ledger,
            "focused deletion redo preserves exact ledger and stopped timer")
        store.undo()
        let reloaded = try store.file.load()
        require(
            reloaded == restored && store.planner == restored,
            "repeated undo restores exact task without runtime rewind")
    }

    try store.file.mutate { planner in
        let i = planner.tasks.firstIndex { $0.id == task.id }!
        planner.tasks[i].notes = "External edit after undo"
    }
    let external = try store.file.load()
    store.redo()
    let afterConflict = try store.file.load()
    require(
        store.planner == external && afterConflict == external,
        "redo preserves external content without an explicit reload")
    require(!store.canRedo, "conflicting deletion redo is consumed without a new inverse")

    for paused in [false, true] {
        store.apply { try $0.delete(task.id.uuidString, on: .day($0.today)) }
        store.undo()
        store.apply { try $0.startTimer(task: task.id.uuidString, minutes: 1) }
        if paused { store.apply { try $0.pauseTimer() } }
        let active = try store.file.load()
        require(
            active.tasks.first { $0.id == task.id }?.focusedSeconds == 60 && store.canRedo,
            "new timer keeps deletion redo available without adding credit")
        store.redo()
        let afterActive = try store.file.load()
        require(store.planner == active && afterActive == active, "deletion redo protects running and paused timers")
    }
    store.apply { _ = $0.stopTimer() }
    store.apply { try $0.delete(task.id.uuidString, on: .day($0.today)) }
    store.undo()
    store.apply { try $0.startTimer(task: task.id.uuidString, minutes: 1) }
    clock.advance(8.5)
    store.apply { _ = $0.stopTimer() }
    let accrued = try store.file.load()
    require(
        accrued.tasks.first { $0.id == task.id }?.focusedSeconds == 68.5 && store.canRedo,
        "new focus after undo accrues separately")
    store.redo()
    let afterAccrual = try store.file.load()
    require(store.planner == accrued && afterAccrual == accrued, "deletion redo protects new focus credit and ledger")
    require(store.lastError == nil, "deletion regression transactions finish without storage errors")
}

@MainActor
func checkNotepadView(_ store: PlannerStore) async throws {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 220), styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: NotepadCard(day: store.today).environmentObject(store))
    window.makeKeyAndOrderFront(nil)
    try await Task.sleep(nanoseconds: 100_000_000)
    @MainActor func editor(_ view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.compactMap(editor).first
    }
    let textView = editor(window.contentView!)
    require(textView != nil, "real notepad NSTextView is mounted")
    let tv = textView!
    tv.string = "Native editor draft"
    tv.didChangeText()
    require(
        store.text(for: .notepad(store.today)) == "Native editor draft",
        "native text-change delegate sends the draft to the store immediately")
    tv.delegate?.textDidEndEditing?(Notification(name: NSText.didEndEditingNotification, object: tv))
    let saved = try store.file.load()
    require(saved.notes.first?.text == "Native editor draft", "native blur delegate flushes notepad")
    tv.string = "Removed view draft"
    tv.didChangeText()
    window.contentView = nil
    try await Task.sleep(nanoseconds: 100_000_000)
    let closed = try store.file.load()
    require(closed.notes.first?.text == "Removed view draft", "removing the notepad view flushes its final edit")
    window.close()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    do {
        let store = try checkStore()
        try await checkNotepadView(store)
        try checkDeletionRedo()
        print("Undo app probe passed")
        exit(0)
    } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
app.run()
