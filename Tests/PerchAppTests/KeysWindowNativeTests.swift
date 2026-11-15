#if KEYS_WINDOW_NATIVE_PROBE
    import AppKit
    import ApplicationServices
    import PerchUI
    import SwiftUI
    @testable import PerchApp
    @testable import PlannerCore

    /// Keyboard ownership is exercised in an application, not the XCTest host.
    @MainActor
    private enum KeysNativeCheck {
        static func run() async throws {
            try require(Bundle.main.bundleIdentifier == nil, "The Keys fixture must run unbundled")
            let primer = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            primer.isReleasedWhenClosed = false
            primer.contentView = NSTextField(labelWithString: "Keyboard fixture")
            primer.orderFront(nil)
            await primeAccessibility()
            primer.close()
            try await testHelpOpensOneWindowAndEscapeClosesItThroughTheEventRouter()
            log("PASS: Keys help, single window, exact size and Escape")
            try await testQuestionMarkInATextEditorIsNotAHelpCommand()
            log("PASS: Keys preserves text-editor punctuation")
            try await testInstalledMonitorLeavesShortcutRecordingInControl()
            log("PASS: Keys preserves shortcut recording, timer, Undo and navigation")
            try await testInstalledMonitorLeavesTaskDetailsSheetInControl()
            log("PASS: Keys preserves sheet editing, Escape, timer, Undo and navigation")
            try await testInstalledMonitorPreservesWindowUndoOwnersAndFallback()
            log("PASS: Keys preserves window Undo ownership and fallback")
        }

        private nonisolated static func primeAccessibility() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    let app = AXUIElementCreateApplication(getpid())
                    var raw: CFTypeRef?
                    _ = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
                    if let windows = raw as? [AXUIElement] {
                        for window in windows {
                            var children: CFTypeRef?
                            _ = AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children)
                        }
                    }
                    continuation.resume()
                }
            }
        }

        private static func log(_ message: String) {
            FileHandle.standardError.write(Data("\(message)\n".utf8))
        }

        static func testHelpOpensOneWindowAndEscapeClosesItThroughTheEventRouter() async throws {
            let fixture = try KeysNativeFixture()
            defer { fixture.cleanUp(); WindowHost.windows["keys"]?.close() }
            let source = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            source.isReleasedWhenClosed = false
            defer { source.close() }
            try await activate(source)
            try require(NSApp.keyWindow === source)
            let model = NotchModel()
            let router = KeysShortcutRouter(store: fixture.store, model: model)
            try require(router.handle(event(code: 44, characters: "?", window: source, modifiers: .shift)))
            let window = try unwrap(WindowHost.windows["keys"])
            try require(window.isVisible)
            let contentView = try unwrap(window.contentView)
            try equal(contentView.bounds.width, CGFloat(KeyMap.Layout.width))
            try equal(contentView.bounds.height, CGFloat(KeyMap.Layout.height))
            try require(perform(.showKeys, with: router))
            try require(WindowHost.windows["keys"] === window)
            try await activate(window)
            try require(NSApp.keyWindow === window)
            let escape = event(code: 53, characters: "\u{1b}", window: window)
            try require(router.handle(escape))
            try reject(window.isVisible)
            try await waitFor("Closing Keys must clear its window registration") { WindowHost.windows["keys"] == nil }
            router.start()
            try await activate(source)
            NSApp.sendEvent(event(code: 44, characters: "?", window: source, modifiers: .shift))
            try await waitFor("The installed monitor must open Keys") { WindowHost.windows["keys"]?.isVisible == true }
            let reopened = try unwrap(WindowHost.windows["keys"])
            try require(reopened !== window)
            try await activate(reopened)
            NSApp.sendEvent(event(code: 53, characters: "\u{1b}", window: reopened))
            try await waitFor("The installed monitor must close Keys") { !reopened.isVisible }
            withExtendedLifetime(router) {}
        }

        static func testQuestionMarkInATextEditorIsNotAHelpCommand() async throws {
            let fixture = try KeysNativeFixture()
            defer { fixture.cleanUp() }
            let router = KeysShortcutRouter(store: fixture.store, model: NotchModel())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let editor = NSTextView(frame: window.contentView!.bounds)
            window.contentView = editor
            try await activate(window)
            try require(window.makeFirstResponder(editor))
            let question = event(code: 44, characters: "?", window: window, modifiers: .shift)
            try reject(router.handle(question))
            editor.insertText("?", replacementRange: NSRange(location: NSNotFound, length: 0))
            try equal(editor.string, "?")
        }

        static func testInstalledMonitorLeavesShortcutRecordingInControl() async throws {
            let savedShortcut = UserDefaults.standard.object(forKey: ShortcutStore.defaultsKey)
            defer {
                if let savedShortcut {
                    UserDefaults.standard.set(savedShortcut, forKey: ShortcutStore.defaultsKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: ShortcutStore.defaultsKey)
                }
            }
            let fixture = try KeysNativeFixture()
            defer { fixture.cleanUp() }
            let task = try unwrap(
                fixture.store.addTasks(["Keep the running task"], on: .day(fixture.store.today))?.first)
            try require(fixture.store.send(.startTimer(task.id, minutes: 25)) != nil)
            try require(fixture.store.addTasks(["Preserve this Undo entry"], on: .day(fixture.store.today)) != nil)
            let before = fixture.store.planner
            let router = KeysShortcutRouter(store: fixture.store, model: NotchModel())
            router.start()
            defer { withExtendedLifetime(router) {} }
            let navigation = NavigationCount()
            let token = NotificationCenter.default.addObserver(forName: .perchOpenWorkspace, object: nil, queue: .main)
            {
                _ in MainActor.assumeIsolated { navigation.value += 1 }
            }
            defer { NotificationCenter.default.removeObserver(token) }

            for (code, characters, modifiers) in [
                (UInt16(53), "\u{1b}", NSEvent.ModifierFlags()),
                (UInt16(19), "2", NSEvent.ModifierFlags.command),
                (UInt16(35), "p", NSEvent.ModifierFlags.command),
                (UInt16(6), "z", NSEvent.ModifierFlags.command),
            ] {
                ShortcutStore.save(.default, notify: false)
                let window = makeWindow()
                defer { window.close() }
                window.contentView = NSHostingView(
                    rootView: ShortcutPreferenceRow().padding()
                        .environment(\.accessibilityEnabled, true))
                try await activate(window)
                let button = try await control(in: window) {
                    self.attribute($0, "accessibilityRole") as? String == "AXButton"
                        && (self.attribute($0, "accessibilityLabel") as? String == ShortcutKey.default.display
                            || self.attribute($0, "accessibilityTitle") as? String == ShortcutKey.default.display)
                }
                try press(button)
                try await waitFor("The real shortcut recorder must own input") {
                    window.firstResponder is KeysShortcutInputOwner
                }
                try require(window === NSApp.keyWindow)
                NSApp.sendEvent(event(code: code, characters: characters, window: window, modifiers: modifiers))
                try await waitFor("Recording must finish without closing the window") {
                    !(window.firstResponder is KeysShortcutInputOwner)
                }
                try require(window.isVisible)
                let expected =
                    code == 53 ? ShortcutKey.default : ShortcutKey(keyCode: UInt32(code), modifiers: .command)
                try equal(ShortcutStore.load(), expected)
                try equal(fixture.store.planner, before)
                try require(fixture.store.canUndo)
                try reject(fixture.store.canRedo)
            }
            try await Task.sleep(for: .milliseconds(50))
            try equal(navigation.value, 0, "Native inputs must not navigate the workspace")
            fixture.store.undo()
            try equal(
                fixture.store.planner.tasks.map(\.id), [task.id], "Recording must preserve the original Undo entry")
        }

        static func testInstalledMonitorLeavesTaskDetailsSheetInControl() async throws {
            let fixture = try KeysNativeFixture()
            defer { fixture.cleanUp() }
            let task = try unwrap(
                fixture.store.addTasks(["Keep sheet edits local"], on: .day(fixture.store.today))?.first)
            try require(fixture.store.send(.startTimer(task.id, minutes: 25)) != nil)
            try require(fixture.store.addTasks(["Preserve this Undo entry"], on: .day(fixture.store.today)) != nil)
            let router = KeysShortcutRouter(store: fixture.store, model: NotchModel())
            router.start()
            defer { withExtendedLifetime(router) {} }
            let navigation = NavigationCount()
            let token = NotificationCenter.default.addObserver(forName: .perchOpenWorkspace, object: nil, queue: .main)
            {
                _ in MainActor.assumeIsolated { navigation.value += 1 }
            }
            defer { NotificationCenter.default.removeObserver(token) }
            let presentation = KeysDetailsPresentation()
            let window = makeWindow()
            defer {
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
                window.close()
            }
            window.contentView = NSHostingView(
                rootView: KeysDetailsPresenter(presentation: presentation, store: fixture.store, taskID: task.id))
            try await activate(window)
            presentation.isPresented = true
            try await waitFor("The task-details sheet must be attached") { window.attachedSheet != nil }
            let sheet = try unwrap(window.attachedSheet)
            try await activate(sheet)
            try require(sheet.isSheet)
            try require(sheet.sheetParent === window)
            try isNil(sheet.attachedSheet)
            let titleControl = try await control(in: sheet) {
                ($0 as? NSTextField)?.placeholderString == "Task title"
            }
            let field = try unwrap(titleControl as? NSTextField)
            try require(sheet.makeFirstResponder(field))
            try await waitFor("The sheet title must have a text editor") { sheet.firstResponder is NSTextView }
            let editor = try unwrap(sheet.firstResponder as? NSTextView)
            editor.selectAll(nil)
            editor.insertText("Discard this draft", replacementRange: NSRange(location: NSNotFound, length: 0))
            let before = fixture.store.planner
            let cancel = try await control(in: sheet) {
                self.attribute($0, "accessibilityIdentifier") as? String == "details-cancel"
            }
            for textFocused in [true, false] {
                if !textFocused {
                    let selector = NSSelectorFromString("setAccessibilityFocused:")
                    let implementation = try unwrap(cancel.responds(to: selector) ? cancel.method(for: selector) : nil)
                    typealias Focus = @convention(c) (AnyObject, Selector, Bool) -> Void
                    unsafeBitCast(implementation, to: Focus.self)(cancel, selector, true)
                    try await waitFor("The sheet Cancel button must own focus") {
                        let getter = NSSelectorFromString("isAccessibilityFocused")
                        guard cancel.responds(to: getter), let method = cancel.method(for: getter) else { return false }
                        typealias Focused = @convention(c) (AnyObject, Selector) -> Bool
                        return unsafeBitCast(method, to: Focused.self)(cancel, getter)
                    }
                    try reject(sheet.firstResponder is NSTextView)
                }
                for (code, characters) in [(UInt16(35), "p"), (UInt16(24), "+"), (UInt16(19), "2"), (UInt16(6), "z")] {
                    try require(sheet === NSApp.keyWindow)
                    NSApp.sendEvent(event(code: code, characters: characters, window: sheet, modifiers: .command))
                    try equal(fixture.store.planner, before)
                    try require(fixture.store.canUndo)
                    try reject(fixture.store.canRedo)
                    try require(presentation.isPresented)
                }
            }
            NSApp.sendEvent(event(code: 53, characters: "\u{1b}", window: sheet))
            try await waitFor("Escape must reach the sheet's Cancel action") {
                !presentation.isPresented && window.attachedSheet == nil
            }
            try equal(fixture.store.planner, before)
            try await Task.sleep(for: .milliseconds(50))
            try equal(navigation.value, 0, "Native inputs must not navigate the workspace")
            fixture.store.undo()
            try equal(
                fixture.store.planner.tasks.map(\.id), [task.id], "The sheet must preserve the original Undo entry")
        }

        static func testInstalledMonitorPreservesWindowUndoOwnersAndFallback() async throws {
            let fallback = try KeysNativeFixture()
            defer { fallback.cleanUp() }
            try require(fallback.store.addTasks(["Keep the fallback history"], on: .day(fallback.store.today)) != nil)
            let fallbackBefore = fallback.store.planner
            let model = NotchModel()
            let router = KeysShortcutRouter(store: fallback.store, model: model)
            router.start()
            defer { withExtendedLifetime(router) {} }

            for notch in [true, false] {
                let owner = try KeysNativeFixture()
                defer { owner.cleanUp() }
                let first = try unwrap(
                    owner.store.addTasks(["First window change"], on: .day(owner.store.today))?.first)
                try require(owner.store.addTasks(["Second window change"], on: .day(owner.store.today)) != nil)
                var calls: [Bool] = []
                let onUndo: (Bool) -> Void = { redo in
                    calls.append(redo)
                    if redo { owner.store.redo() } else { owner.store.undo() }
                }
                let window: NSWindow
                if notch {
                    let panel = NotchPanel(frame: NSRect(x: 50, y: 100, width: 400, height: 200))
                    panel.isReleasedWhenClosed = false
                    panel.ignoresMouseEvents = false
                    panel.onUndo = onUndo
                    panel.contentView = NSTextField(labelWithString: "Window Undo owner")
                    window = panel
                } else {
                    WindowHost.show(
                        "keys-undo-fixture", title: "Window Undo owner",
                        size: CGSize(width: 400, height: 200), onUndo: onUndo
                    ) {
                        Text("Window Undo owner")
                    }
                    window = try unwrap(WindowHost.windows["keys-undo-fixture"])
                }
                defer { window.close() }
                try await activate(window)
                try require(window.makeFirstResponder(nil))
                try reject(window.firstResponder is NSTextView)

                for remaining in [1, 0] {
                    NSApp.sendEvent(event(code: 6, characters: "z", window: window, modifiers: .command))
                    try equal(owner.store.planner.tasks.count, remaining, "Undo must reach the window's store")
                    try equal(calls, Array(repeating: false, count: 2 - remaining), "One callback per Command-Z")
                    try equal(try owner.store.file.load().tasks, owner.store.planner.tasks)
                    try equal(fallback.store.planner, fallbackBefore, "Window Undo must not touch fallback history")
                }
                // A window owner still consumes Undo when its own history is empty.
                NSApp.sendEvent(event(code: 6, characters: "z", window: window, modifiers: .command))
                try equal(calls, [false, false, false])
                try require(owner.store.planner.tasks.isEmpty)
                try equal(fallback.store.planner, fallbackBefore)

                NSApp.sendEvent(event(code: 6, characters: "z", window: window, modifiers: [.command, .shift]))
                try equal(calls, [false, false, false, true], "Window Redo must still run once")
                try equal(owner.store.planner.tasks.map(\.id), [first.id])
                try equal(try owner.store.file.load().tasks, owner.store.planner.tasks)
                try equal(fallback.store.planner, fallbackBefore)
                try reject(fallback.store.canRedo)
            }

            let plain = makeWindow()
            defer { plain.close() }
            plain.contentView = NSTextField(labelWithString: "No window Undo handler")
            try await activate(plain)
            try require(plain.makeFirstResponder(nil))
            try reject(plain.firstResponder is NSTextView)
            NSApp.sendEvent(event(code: 6, characters: "z", window: plain, modifiers: .command))
            try require(fallback.store.planner.tasks.isEmpty, "An unhandled window must use the catalog fallback")
            try require(fallback.store.canRedo)
            try require(try fallback.store.file.load().tasks.isEmpty)
            try reject(
                router.handle(event(code: 6, characters: "z", window: plain, modifiers: .command)),
                "An unhandled Undo with empty history must not be consumed")
        }

        private static func makeWindow() -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 780),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            return window
        }

        private static func activate(_ window: NSWindow) async throws {
            try await waitFor("Native key events require an active key window") {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.contentView?.layoutSubtreeIfNeeded()
                log(
                    "Keys activation: policy=\(NSApp.activationPolicy().rawValue) active=\(NSApp.isActive) "
                        + "expected=\(window.windowNumber) key=\(String(describing: NSApp.keyWindow?.windowNumber))")
                return NSApp.isActive && window === NSApp.keyWindow
            }
        }

        private static func waitFor(_ message: String, _ predicate: () -> Bool) async throws {
            for _ in 0..<30 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw KeysNativeFailure(message: message)
        }

        private static func control(in window: NSWindow, matching predicate: (NSObject) -> Bool) async throws
            -> NSObject
        {
            try await waitFor("The native control must be available") { nodes(window).contains(where: predicate) }
            return try unwrap(nodes(window).first(where: predicate))
        }

        private static func attribute(_ node: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
        }

        private static func nodes(_ root: NSObject) -> [NSObject] {
            var seen = Set<ObjectIdentifier>()
            @MainActor func walk(_ node: NSObject) -> [NSObject] {
                guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
                var children = [
                    "accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder",
                ]
                .flatMap { attribute(node, $0) as? [NSObject] ?? [] }
                if let view = node as? NSView { children += view.subviews }
                if let window = node as? NSWindow, let content = window.contentView { children.append(content) }
                return [node] + children.flatMap(walk)
            }
            return walk(root)
        }

        private static func press(_ node: NSObject) throws {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            let implementation = try unwrap(node.responds(to: selector) ? node.method(for: selector) : nil)
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            try require(unsafeBitCast(implementation, to: Press.self)(node, selector))
        }

        private static func perform(_ action: KeyMap.Action, with router: KeysShortcutRouter) -> Bool {
            let entry = KeyMap.allEntries.first { $0.id == action }!
            return router.bindings.handle(entry.gestures[0].example, context: .application)
        }

        private static func event(
            code: UInt16, characters: String, window: NSWindow, modifiers: NSEvent.ModifierFlags = []
        )
            -> NSEvent
        {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                keyCode: code)!
        }

    }

    @MainActor private final class NavigationCount { var value = 0 }
    private struct KeysNativeFailure: Error { let message: String }

    @MainActor private func require(_ value: Bool, _ message: String = "Expected true", line: UInt = #line) throws {
        guard value else { throw KeysNativeFailure(message: "line \(line): \(message)") }
    }
    @MainActor private func reject(_ value: Bool, _ message: String = "Expected false", line: UInt = #line) throws {
        try require(!value, message, line: line)
    }
    @MainActor private func equal<T: Equatable>(
        _ actual: T, _ expected: T, _ message: String = "Values differ", line: UInt = #line
    ) throws {
        try require(actual == expected, "\(message): \(actual) != \(expected)", line: line)
    }
    @MainActor private func isNil<T>(_ value: T?, line: UInt = #line) throws {
        try require(value == nil, "Expected nil", line: line)
    }
    @MainActor private func unwrap<T>(_ value: T?, line: UInt = #line) throws -> T {
        guard let value else { throw KeysNativeFailure(message: "line \(line): Missing value") }
        return value
    }

    private enum KeysNativeProbe {
        static func run() {
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.regular)
                Task { @MainActor in
                    do {
                        try await KeysNativeCheck.run()
                        exit(0)
                    } catch {
                        FileHandle.standardError.write(Data("FAIL: Keys native keyboard: \(error)\n".utf8))
                        exit(1)
                    }
                }
                app.run()
            }
        }
    }

    @MainActor
    private final class KeysDetailsPresentation: ObservableObject {
        @Published var isPresented = false
    }

    @MainActor
    private struct KeysDetailsPresenter: View {
        @ObservedObject var presentation: KeysDetailsPresentation
        let store: PlannerStore
        let taskID: UUID

        var body: some View {
            Text("Synthetic task host").frame(width: 640, height: 780)
                .sheet(isPresented: $presentation.isPresented) {
                    TaskDetailsSheet(taskID: taskID).environmentObject(store)
                        .environment(\.accessibilityEnabled, true)
                }
        }
    }

    @MainActor
    private struct KeysNativeFixture {
        let directory: URL
        let store: PlannerStore

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let file = PlannerFile(
                url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
            store = PlannerStore(file: file, now: { PlannerPreviewScenarios.referenceDate }, watching: false)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }
#else
    import Foundation
    import XCTest

    /// XCTest itself cannot reliably become a key application on hosted macOS.
    /// Compile this file as an unbundled native executable and retain every key/focus assertion.
    final class KeysWindowNativeTests: XCTestCase {
        func testKeysWindowAndInputOwnershipThroughNativeApplication() throws {
            let source = URL(fileURLWithPath: #filePath)
            let root = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            for item in ["Package.swift", "Sources", "Tests"] {
                try FileManager.default.copyItem(
                    at: root.appendingPathComponent(item), to: temporary.appendingPathComponent(item))
            }
            let main = temporary.appendingPathComponent("Sources/Perch/main.swift")
            let program = try String(contentsOf: source, encoding: .utf8) + "\nKeysNativeProbe.run()\n"
            try program.write(to: main, atomically: true, encoding: .utf8)
            let log = temporary.appendingPathComponent("keyboard.log")
            XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [
                "-c",
                #"""
                import os, pathlib, subprocess, sys
                package = sys.argv[1]
                subprocess.run([
                    'swift', 'build', '--jobs', '2', '--package-path', package,
                    '-Xswiftc', '-DKEYS_WINDOW_NATIVE_PROBE', '-Xswiftc', '-enable-testing',
                    '--product', 'Perch',
                ], check=True, timeout=300)
                bin_path = subprocess.check_output([
                    'swift', 'build', '--show-bin-path', '--package-path', package,
                ], text=True, timeout=30).strip()
                subprocess.run([
                    str(pathlib.Path(bin_path) / 'Perch'), '-AppleKeyboardUIMode', '3',
                ], check=True, timeout=120)
                """#, temporary.path,
            ]
            process.currentDirectoryURL = temporary
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let result = try String(contentsOf: log, encoding: .utf8)
            FileHandle.standardError.write(Data(result.utf8))
            XCTAssertEqual(process.terminationReason, .exit)
            XCTAssertEqual(process.terminationStatus, 0, "Native Keys keyboard check failed:\n\(result)")
            for marker in [
                "PASS: Keys help, single window, exact size and Escape",
                "PASS: Keys preserves text-editor punctuation",
                "PASS: Keys preserves shortcut recording, timer, Undo and navigation",
                "PASS: Keys preserves sheet editing, Escape, timer, Undo and navigation",
                "PASS: Keys preserves window Undo ownership and fallback",
            ] {
                XCTAssertEqual(result.components(separatedBy: marker).count - 1, 1, "Missing or duplicate: \(marker)")
            }
        }
    }
#endif
