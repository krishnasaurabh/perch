// Replaces App/main.swift only in the temporary CI probe package. Uses the actual views/controller.
import AppKit
import PlannerCore

@MainActor
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
    print("PASS: \(message)")
}

@MainActor
func settle() async {
    try? await Task.sleep(nanoseconds: 900_000_000)
}

@MainActor
func captureEditor() -> NSTextView? {
    // Unlike the notepad's NSTextView, a TextField uses the window's field editor.
    guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
    return editor
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EMPTY_STATES_OUTPUT"]!)

    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        Task { @MainActor in
            require(delegate.store.planner.tasks.isEmpty, "isolated planner starts empty")
            require(!delegate.model.expanded, "normal launch starts closed")
            delegate.store.updatePrefs { $0.catchCopies = false; $0.catchScreenshots = false }
            // A passive reveal must leave another window's editor alone.
            let other = NSPanel(contentRect: NSRect(x: 80, y: 80, width: 180, height: 80),
                                styleMask: [.titled], backing: .buffered, defer: false)
            let otherField = NSTextField(frame: NSRect(x: 10, y: 10, width: 160, height: 24))
            other.contentView?.addSubview(otherField)
            NSApp.activate(ignoringOtherApps: true)
            other.makeKeyAndOrderFront(nil)
            other.makeFirstResponder(otherField)
            await settle()
            require(other.isKeyWindow, "passive-focus fixture starts as the key window")
            delegate.model.open()
            await settle()
            require(other.isKeyWindow, "passive reveal preserves another window's keyboard focus")
            require(delegate.model.captureFocusRequest == nil, "passive reveal does not request capture")
            delegate.model.close()
            await settle()
            other.orderOut(nil)
            NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.home)
            await settle()
            require(captureEditor() != nil, "Today opening focuses a text field")
            NSApp.keyWindow?.makeFirstResponder(nil)
            require(captureEditor() == nil, "capture can yield focus to another control")
            NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.home)
            await settle()
            require(captureEditor() != nil, "explicit opening refocuses an already-open Today")
            delegate.notch.snapshot(into: output.appendingPathComponent("today-empty"))

            for page in [NotchPage.week, .clips] {
                delegate.model.page = page
                await settle()
                delegate.notch.snapshot(into: output.appendingPathComponent("\(page.rawValue)-empty"))
            }
            // Page switch and full close/reopen both remount the composer.
            delegate.model.page = .home
            await settle()
            require(captureEditor() != nil, "returning to Today focuses capture")
            delegate.model.close()
            await settle()
            NotificationCenter.default.post(name: .perchOpenWorkspace, object: NotchPage.home)
            await settle()
            require(captureEditor() != nil, "reopening focuses capture")

            captureEditor()?.insertText("Capture probe task", replacementRange: NSRange(location: NSNotFound, length: 0))
            await settle()
            require(captureEditor()?.string == "Capture probe task", "typing without a click reaches capture")
            if let window = NSApp.keyWindow,
               let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, characters: "\r",
                                            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                NSApp.sendEvent(enter)
            }
            await settle()
            require(delegate.store.planner.tasks.count == 1, "Return creates one task")
            require(delegate.store.planner.tasks.first?.title == "Capture probe task", "capture text is persisted")
            require(captureEditor()?.string == "", "capture clears and stays focused after add")
            delegate.notch.snapshot(into: output.appendingPathComponent("today-populated"))

            let id = delegate.store.planner.tasks[0].id
            delegate.store.apply { try $0.complete(id.uuidString) }
            await settle()
            delegate.notch.snapshot(into: output.appendingPathComponent("today-cleared"))
            require(delegate.store.engine.insights().allTimeCompleted == 1, "first completion records Insights progress")
            delegate.store.apply { engine in
                engine.planner.tasks = []
                _ = engine.startStopwatch(taskID: nil)
                let later = Date().addingTimeInterval(60)
                engine.now = { later }
                _ = engine.stopTimer()
            }
            await settle()
            let focusOnly = delegate.store.engine.insights()
            require(focusOnly.allTimeCompleted == 0 && focusOnly.allTimeFocusSeconds > 0,
                    "focus alone is Insights progress without a completed task")
            // Insights is its own page now (w3/ui-home-clean), so the focus-only state is captured there.
            delegate.model.page = .insights
            await settle()
            delegate.notch.snapshot(into: output.appendingPathComponent("insights-focus-only"))
            delegate.model.page = .home
            require(delegate.store.lastError == nil, "empty-state transitions report no store error")
            for symbol in ["square.and.pencil", "checkmark.circle", "calendar", "tray", "paperclip", "chart.bar"] {
                require(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                        "SF Symbol exists: \(symbol)")
            }
            for name in ["today-empty", "week-empty", "clips-empty", "today-populated", "today-cleared", "insights-focus-only"] {
                let files = (try? FileManager.default.contentsOfDirectory(at: output.appendingPathComponent(name),
                                                                         includingPropertiesForKeys: nil)) ?? []
                require(files.contains { $0.pathExtension == "png" && NSImage(contentsOf: $0) != nil },
                        "snapshot exists and decodes: \(name)")
            }
            print("Empty-state and capture smoke passed. Snapshots: \(output.path)")
            exit(0)
        }
    }
    withExtendedLifetime(delegate) { app.run() }
}
