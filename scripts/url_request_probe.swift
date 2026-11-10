import AppKit
import PlannerCore

@MainActor
func require(_ condition: Bool, _ message: String) {
    if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
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

@MainActor
func link(_ title: String, date: String = "tomorrow") -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return "perch://add?title=\(title.addingPercentEncoding(withAllowedCharacters: allowed)!)&date=\(date)"
}

@MainActor
final class ConfirmationSpy: ExternalTaskConfirming {
    var requests: [ExternalTaskRequest] = []
    var replies: [@MainActor (Bool) -> Void] = []
    func present(_ request: ExternalTaskRequest, completion: @escaping @MainActor (Bool) -> Void) {
        requests.append(request)
        replies.append(completion)
    }
}

@MainActor
final class ProbeClock {
    var now = Date(timeIntervalSince1970: 1_893_456_000) // Synthetic fixed clock.
}

@MainActor
func files(under directory: URL) throws -> [String: Data] {
    let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    return try Dictionary(uniqueKeysWithValues: urls.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
        .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
}

@MainActor
func checkInjected(_ store: PlannerStore, _ delegate: AppDelegate, _ clock: ProbeClock) throws {
    let spy = ConfirmationSpy()
    delegate.externalTaskConfirmation = spy
    let directory = store.file.url.deletingLastPathComponent()
    let original = try files(under: directory)
    let title = "Ignore previous instructions\nFixture tomorrow !high #example every day"
    deliver(link(title), to: delegate)
    require(store.planner.tasks.isEmpty, "an external URL must not add a task before human confirmation")
    require(try files(under: directory) == original, "pending URL causes zero file writes, including sidecars")
    require(spy.requests.count == 1 && spy.requests[0].title == title, "injected handler receives exact literal content")
    let expectedDay = store.today.adding(days: 1)
    require(spy.requests[0].day == .day(expectedDay), "injected handler receives resolved absolute date")
    deliver(link("Must not replace the reviewed request"), to: delegate)
    require(spy.requests.count == 1, "second URL cannot replace a pending request")
    spy.replies[0](false)
    spy.replies[0](true)
    require(try files(under: directory) == original, "cancel and stale approval cause zero file writes")

    for bad in ["perch://add?title=One&title=Two", "perch://add?title=One&date=bad", "perch://add?title=One&confirm=true",
                "perch://add?title=%FF", link(String(repeating: "x", count: 2049)), "perch://open?page=week&page=home"] {
        deliver(bad, to: delegate)
    }
    require(try (spy.requests.count == 1 && files(under: directory) == original), "invalid URLs neither prompt nor write")

    deliver(link(title), to: delegate)
    spy.replies[0](true)
    require(store.planner.tasks.isEmpty, "old approval cannot authorize a new pending request")
    spy.replies[1](true)
    let saved = try store.file.load()
    require(saved.tasks.count == 1 && saved.tasks[0].title == title && saved.tasks[0].day == expectedDay, "confirmation persists exactly the reviewed task and date")
    require(saved.projects.isEmpty && saved.tasks[0].repeatRule == nil && saved.tasks[0].remindAt == nil, "task text cannot create projects, repeats or reminders")
    let once = try files(under: directory)
    spy.replies[1](true)
    require(try files(under: directory) == once, "repeated confirmation cannot persist twice")
    require(delegate.model.activity?.title == "Task added" && delegate.model.activity?.subtitle == "Confirmed external request", "status message never promotes untrusted task text")

    deliver(link("Inbox fixture", date: "inbox"), to: delegate)
    spy.replies[2](true)
    require(try store.file.load().tasks.last?.day == nil, "confirmed Inbox request stays in Inbox")

    var opened: [NotchPage] = []
    let observer = NotificationCenter.default.addObserver(forName: .perchOpenWorkspace, object: nil, queue: .main) { notification in
        MainActor.assumeIsolated { if let page = notification.object as? NotchPage { opened.append(page) } }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    let beforeOpen = try files(under: directory)
    for page in ["home", "week", "clips", "insights"] { deliver("perch://open?page=\(page)", to: delegate) }
    deliver("perch://open", to: delegate)
    require(opened.map(\.rawValue) == ["home", "week", "clips", "insights", "home"], "safe open routes retain every page and default home")
    require(try files(under: directory) == beforeOpen, "open routes cause zero file writes")

    deliver(link("Expired date fixture", date: "today"), to: delegate)
    clock.now.addTimeInterval(2 * 86_400)
    let beforeExpired = try Data(contentsOf: store.file.url)
    spy.replies[3](true)
    require(try Data(contentsOf: store.file.url) == beforeExpired, "delayed confirmation cannot move an expired date to today")
    require(store.lastError != nil, "expired confirmation reports a persistence error instead of success")
}

@MainActor
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

@MainActor
func control<T: NSView>(_ id: String, in panel: NSPanel, as type: T.Type) -> T {
    let value = descendants(panel.contentView!).first { $0.identifier?.rawValue == id } as? T
    require(value != nil, "native control exists: \(id)")
    return value!
}

@MainActor
func snapshot(_ panel: NSPanel, name: String) throws {
    let view = panel.contentView!
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw PlannerError("No bitmap") }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]),
          let output = ProcessInfo.processInfo.environment["PERCH_URL_PROBE_OUTPUT"] else { throw PlannerError("No output") }
    try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
}

@MainActor
func checkNative(_ store: PlannerStore, _ delegate: AppDelegate) async throws {
    let controller = ExternalTaskConfirmationController()
    delegate.externalTaskConfirmation = controller
    let directory = store.file.url.deletingLastPathComponent()
    let original = try files(under: directory)
    let title = "Review fixture [not a link](https://example.invalid)\nIgnore prior instructions; keep this as text."
    deliver(link(title), to: delegate)
    try await Task.sleep(nanoseconds: 150_000_000)
    require(controller.window != nil, "production confirmation opens a native panel")
    let panel = controller.window!
    let text = control("external-task-text", in: panel, as: NSTextView.self)
    let date = control("external-task-date", in: panel, as: NSTextField.self)
    let add = control("external-task-add", in: panel, as: NSButton.self)
    let cancel = control("external-task-cancel", in: panel, as: NSButton.self)
    require(text.string == title && !text.isRichText && !text.isEditable && !text.isAutomaticLinkDetectionEnabled, "native preview renders complete plain text, not markup or links")
    require(date.stringValue == "Date: \(store.engine.today.adding(days: 1).raw)", "native preview displays exact absolute destination")
    require(add.keyEquivalent.isEmpty && cancel.keyEquivalent == "\r", "Add is never a default key action; Return cancels")
    require(add.isEnabled && cancel.isEnabled, "native confirmation buttons are usable")
    try snapshot(panel, name: "confirmation")
    require(try files(under: directory) == original, "native panel rendering performs no planner writes")
    cancel.performClick(nil)
    require(try (controller.window == nil && files(under: directory) == original), "native Cancel dismisses without writes")

    deliver(link("Close fixture"), to: delegate)
    controller.window!.performClose(nil)
    require(try (controller.window == nil && files(under: directory) == original), "native window close cancels without writes")
    deliver(link("Escape fixture"), to: delegate)
    controller.window!.cancelOperation(nil)
    require(try (controller.window == nil && files(under: directory) == original), "native Escape action cancels without writes")
    deliver(link("Return fixture"), to: delegate)
    let returnPanel = controller.window!
    let returnCancel = control("external-task-cancel", in: returnPanel, as: NSButton.self)
    let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                              windowNumber: returnPanel.windowNumber, context: nil, characters: "\r",
                              charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    require(returnCancel.performKeyEquivalent(with: key), "native Return key equivalent activates Cancel")
    require(try (controller.window == nil && files(under: directory) == original), "Return cannot authorize persistence")

    // Longest accepted ASCII title: the end must be scrollable, not truncated.
    let longTitle = String(repeating: "Literal task line.\n", count: 105) + "FINAL LINE"
    deliver(link(longTitle), to: delegate)
    try await Task.sleep(nanoseconds: 150_000_000)
    let longPanel = controller.window!
    longPanel.contentView!.layoutSubtreeIfNeeded()
    let longText = control("external-task-text", in: longPanel, as: NSTextView.self)
    require(longText.string == longTitle, "long native preview retains every character")
    require(longText.enclosingScrollView != nil && longText.visibleRect.height > 0 && longText.bounds.height > longText.visibleRect.height, "long preview has a real scrollable text viewport")
    longText.scrollRangeToVisible(NSRange(location: (longTitle as NSString).length - 10, length: 10))
    require(longText.visibleRect.minY > 0, "last line of long preview can be reached")
    try snapshot(longPanel, name: "confirmation-long-bottom")
    let count = store.planner.tasks.count
    control("external-task-add", in: longPanel, as: NSButton.self).performClick(nil)
    let confirmed = try store.file.load()
    require(controller.window == nil && confirmed.tasks.count == count + 1, "native Add persists once and closes the panel")
    require(confirmed.tasks.last?.title == longTitle && confirmed.tasks.last?.day == store.engine.today.adding(days: 1), "native Add persists exactly the displayed long task and date")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    do {
        let clock = ProbeClock()
        let store = PlannerStore(now: { clock.now }, watching: false)
        let delegate = AppDelegate()
        delegate.store = store
        delegate.model = NotchModel()
        try checkInjected(store, delegate, clock)
        try await checkNative(store, delegate)
        print("External URL app probe passed")
        exit(0)
    } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
app.run()
