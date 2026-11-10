import AppKit
import PlannerCore

@MainActor
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}

@MainActor
func runProbe() throws {
    let store = PlannerStore()
    let task = store.apply { try $0.addTasks(["Undo fixture"], on: .day($0.today)) }![0]
    store.apply { try $0.startTimer(task: task.id.uuidString, minutes: 5) }
    store.updateTask(task.id) { $0.title = "Edited fixture" }
    store.apply { try $0.pauseTimer() }
    store.undo()
    require(store.planner.focus?.state == .paused, "Undo must not resume a paused timer")
    require(store.planner.tasks.first?.title == "Undo fixture", "timer actions must not consume user edit history")
    store.redo()
    require(store.planner.focus?.state == .paused, "Redo must not resume a paused timer")
    require(store.planner.tasks.first?.title == "Edited fixture", "Redo restores only the user edit")
    print("Undo app probe passed")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    do { try runProbe(); exit(0) }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
app.run()
