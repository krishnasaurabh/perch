import AppKit
import PlannerCore

@MainActor
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}

@MainActor
func deliver(_ text: String, to delegate: AppDelegate) {
    let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass),
                                       eventID: AEEventID(kAEGetURL), targetDescriptor: nil,
                                       returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    event.setParam(NSAppleEventDescriptor(string: text), forKeyword: keyDirectObject)
    delegate.handleURL(event, reply: NSAppleEventDescriptor.null())
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    do {
        let store = PlannerStore(watching: false)
        let delegate = AppDelegate()
        delegate.store = store
        delegate.model = NotchModel()
        let existed = FileManager.default.fileExists(atPath: store.file.url.path)
        let original = try? Data(contentsOf: store.file.url)
        deliver("perch://add?title=External%20fixture&date=tomorrow", to: delegate)
        require(store.planner.tasks.isEmpty, "an external URL must not add a task before human confirmation")
        require(FileManager.default.fileExists(atPath: store.file.url.path) == existed && (try? Data(contentsOf: store.file.url)) == original,
                "an external URL must not persist anything before human confirmation")
        print("External URL app probe passed")
        exit(0)
    }
}
app.run()
