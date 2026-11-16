#if NOTCH_PEEK_AX_PROBE
    import AppKit
    import ApplicationServices
    import PerchUI
    import PlannerCore
    import SwiftUI
    @testable import PerchApp

    @MainActor
    private final class NotchPeekAccessibilityCheck {
        @MainActor
        func testStandaloneBlockKeepsItsTimeAndActionWithoutBorrowingTaskContent() async throws {
            _ = NSApplication.shared
            try peekRequire(Bundle.main.bundleIdentifier == nil, "Native peek must run unbundled")
            let primer = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            primer.isReleasedWhenClosed = false
            primer.contentView = NSTextField(labelWithString: "Peek fixture")
            primer.orderFront(nil)
            await Self.primeAccessibility()
            primer.close()

            for stopwatch in [false, true] {
                for paused in [false, true] {
                    for hasOtherTask in [false, true] {
                        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        defer { try? FileManager.default.removeItem(at: root) }
                        let file = PlannerFile(
                            url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
                        let now = Date()
                        let store = PlannerStore(file: file, now: { now }, watching: false)
                        if hasOtherTask {
                            let task = try peekUnwrap(store.addTasks(["Unrelated task"], on: .day(store.today))?.first)
                            store.updateTask(task.id) { $0.steps = [Subtask(title: "Unrelated step")] }
                        }
                        if stopwatch {
                            store.apply { try $0.startStopwatch(taskID: nil) }
                        } else {
                            store.apply { try $0.startTimer(task: nil, minutes: 25) }
                        }
                        if paused { store.apply { try $0.pauseTimer() } }
                        let tasks = try file.load().tasks
                        let model = NotchModel(motionPolicy: MotionPolicy(reduceMotion: true))
                        model.openPeek()
                        let size = NSSize(width: NotchPeekLayout.width, height: NotchPeekLayout.contentHeight)
                        let host = NSHostingView(
                            rootView: NotchPeekView()
                                .frame(width: size.width, height: size.height)
                                .environmentObject(store).environmentObject(model)
                                .environment(\.accessibilityEnabled, true)
                                .environment(\.motionPolicyOverride, MotionPolicy(reduceMotion: true)))
                        // Match the production shell's proposed size rather than the scroll view's ideal size.
                        host.sizingOptions = []
                        let window = NSWindow(
                            contentRect: NSRect(
                                x: 0, y: 0, width: NotchPeekLayout.width, height: NotchPeekLayout.contentHeight),
                            styleMask: [.titled], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        window.contentView = host
                        window.setContentSize(size)
                        defer { window.close() }
                        window.center()
                        await activateKeyWindow(window)
                        let all = try await publishedNodes(in: window, host: host)
                        let scenario = "stopwatch-\(stopwatch)-paused-\(paused)-other-task-\(hasOtherTask)"
                        try captureDiagnostics(all, in: window, host: host, scenario: scenario)
                        try peekRequire(window.isKeyWindow, "Peek fixture must own the key window")
                        let labels = all.compactMap { string($0, "accessibilityLabel") }
                        try peekEqual(host.bounds.size.width, size.width, accuracy: 1)
                        try peekEqual(host.bounds.size.height, size.height, accuracy: 1)
                        try peekEqual(
                            all.filter { string($0, "accessibilityIdentifier") == "notch.peek.time" }.count, 1)
                        try peekEqual(
                            all.filter { string($0, "accessibilityIdentifier") == "notch.peek.block" }.count, 1)
                        try peekRequire(!labels.contains("Nothing planned yet"), "Found: \(labels)")
                        try peekRequire(!labels.contains { $0.contains("Unrelated") }, "Found: \(labels)")
                        let time = try peekUnwrap(
                            all.first { string($0, "accessibilityIdentifier") == "notch.peek.time" }, "Found: \(labels)"
                        )
                        try peekRequire(
                            string(time, "accessibilityLabel")?.hasSuffix(stopwatch ? " elapsed" : " left") == true,
                            "Found: \(labels)")
                        let button = try peekUnwrap(
                            all.first { string($0, "accessibilityIdentifier") == "notch.peek.block" },
                            "Found: \(labels)")
                        try peekEqual(string(button, "accessibilityLabel"), paused ? "Continue" : "Pause")
                        let selector = NSSelectorFromString("accessibilityPerformPress")
                        try peekRequire(button.responds(to: selector))
                        let implementation = try peekUnwrap(button.method(for: selector))
                        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                        try peekRequire(unsafeBitCast(implementation, to: Press.self)(button, selector))
                        try await Task.sleep(for: .milliseconds(200))
                        let saved = try file.load()
                        try peekEqual(saved.focus?.state, paused ? .running : .paused)
                        try peekRequire(saved.focus?.taskID == nil)
                        try peekEqual(saved.tasks, tasks)
                        FileHandle.standardError.write(Data("PASS: Peek \(scenario)\n".utf8))
                    }
                }
            }
        }

        @MainActor private func activateKeyWindow(_ window: NSWindow) async {
            let deadline = ContinuousClock.now + .seconds(3)
            repeat {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.contentView?.layoutSubtreeIfNeeded()
                if window.isKeyWindow { return }
                try? await Task.sleep(for: .milliseconds(50))
            } while ContinuousClock.now < deadline
        }

        @MainActor private func publishedNodes(in window: NSWindow, host: NSView) async throws -> [NSObject] {
            let deadline = ContinuousClock.now + .seconds(3)
            var result: [NSObject] = []
            repeat {
                try await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded()
                result = nodes(window)
                let identifiers = Set(result.compactMap { string($0, "accessibilityIdentifier") })
                if identifiers.contains("notch.peek.time"), identifiers.contains("notch.peek.block") { return result }
            } while ContinuousClock.now < deadline
            // Return the failed inventory too: the same exact identity/label/action assertions must fail.
            return result
        }

        @MainActor private func captureDiagnostics(
            _ all: [NSObject], in window: NSWindow, host: NSView, scenario: String
        ) throws {
            let tree = all.map { node in
                "\(type(of: node)) role=\(string(node, "accessibilityRole") ?? "nil") "
                    + "id=\(string(node, "accessibilityIdentifier") ?? "nil") "
                    + "label=\(string(node, "accessibilityLabel") ?? "nil") "
                    + "value=\(string(node, "accessibilityValue") ?? "nil")"
            }.joined(separator: "\n")
            let output =
                "Peek \(scenario): host=\(host.bounds) visible=\(window.isVisible) key=\(window.isKeyWindow) "
                + "responder=\(String(describing: window.firstResponder))\n\(tree)\n"
            FileHandle.standardError.write(Data(output.utf8))
            guard let runner = ProcessInfo.processInfo.environment["RUNNER_TEMP"] else { return }
            let directory = URL(fileURLWithPath: runner).appendingPathComponent("native-diagnostics/notch-peek")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(output.utf8).write(to: directory.appendingPathComponent("\(scenario).txt"))
            let bitmap = try peekUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try peekUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(scenario).png"))
        }

        private nonisolated static func primeAccessibility() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    let app = AXUIElementCreateApplication(getpid())
                    AXUIElementSetMessagingTimeout(app, 2)
                    var raw: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
                    FileHandle.standardError.write(Data("Peek AX root priming: \(status.rawValue)\n".utf8))
                    if let windows = raw as? [AXUIElement] {
                        for window in windows {
                            AXUIElementSetMessagingTimeout(window, 2)
                            var children: CFTypeRef?
                            _ = AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children)
                        }
                    }
                    continuation.resume()
                }
            }
        }

        @MainActor private func value(_ node: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
        }

        @MainActor private func string(_ node: NSObject, _ name: String) -> String? {
            let raw = value(node, name)
            return (raw as? String) ?? (raw as? NSAttributedString)?.string
        }

        @MainActor private func nodes(_ root: NSObject) -> [NSObject] {
            var seen = Set<ObjectIdentifier>()
            var result: [NSObject] = []
            @MainActor func walk(_ node: NSObject, depth: Int) {
                guard depth < 40, seen.insert(ObjectIdentifier(node)).inserted else { return }
                result.append(node)
                var children = [
                    "accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder",
                ]
                .flatMap { value(node, $0) as? [NSObject] ?? [] }
                if let view = node as? NSView { children += view.subviews }
                if let window = node as? NSWindow, let content = window.contentView { children.append(content) }
                for child in children { walk(child, depth: depth + 1) }
            }
            walk(root, depth: 0)
            return result
        }
    }

    // Throwing assertions keep the standalone probe fail-closed without linking XCTest.
    private struct PeekProbeFailure: Error { let message: String }
    private func peekRequire(_ value: Bool, _ message: String = "Assertion failed", line: UInt = #line) throws {
        guard value else { throw PeekProbeFailure(message: "line \(line): \(message)") }
    }
    private func peekEqual<T: Equatable>(
        _ actual: T, _ expected: T, _ message: String = "Values differ", line: UInt = #line
    ) throws {
        try peekRequire(actual == expected, "\(message): \(actual) != \(expected)", line: line)
    }
    private func peekEqual<T: BinaryFloatingPoint>(
        _ actual: T, _ expected: T, accuracy: T, line: UInt = #line
    ) throws {
        try peekRequire(abs(actual - expected) <= accuracy, "Geometry differs: \(actual) != \(expected)", line: line)
    }
    private func peekUnwrap<T>(_ value: T?, _ message: String = "Missing value", line: UInt = #line) throws -> T {
        guard let value else { throw PeekProbeFailure(message: "line \(line): \(message)") }
        return value
    }

    private enum NotchPeekProbe {
        static func run() {
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.regular)
                Task { @MainActor in
                    do {
                        try await NotchPeekAccessibilityCheck()
                            .testStandaloneBlockKeepsItsTimeAndActionWithoutBorrowingTaskContent()
                        exit(0)
                    } catch {
                        FileHandle.standardError.write(Data("FAIL: Peek native accessibility: \(error)\n".utf8))
                        exit(1)
                    }
                }
                app.run()
            }
        }
    }
#else
    import Foundation
    import XCTest

    /// SwiftUI's nested scroll semantics require a real application lifecycle, not the xctest host.
    final class NotchPeekAccessibilityTests: XCTestCase {
        func testStandaloneBlockKeepsItsTimeAndActionWithoutBorrowingTaskContent() throws {
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
            let program = try String(contentsOf: source, encoding: .utf8) + "\nNotchPeekProbe.run()\n"
            try program.write(to: main, atomically: true, encoding: .utf8)
            let log = temporary.appendingPathComponent("peek.log")
            XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [
                "-c",
                #"""
                import itertools, pathlib, subprocess, sys
                package = sys.argv[1]
                subprocess.run([
                    'swift', 'build', '--jobs', '2', '--package-path', package,
                    '-Xswiftc', '-DNOTCH_PEEK_AX_PROBE', '-Xswiftc', '-enable-testing',
                    '--product', 'Perch',
                ], check=True, timeout=300)
                bin_path = subprocess.check_output([
                    'swift', 'build', '--show-bin-path', '--package-path', package,
                ], text=True, timeout=30).strip()
                try:
                    result = subprocess.run([
                        str(pathlib.Path(bin_path) / 'Perch'), '-AppleKeyboardUIMode', '3',
                    ], check=True, timeout=120, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
                    print(error.stdout or '', flush=True)
                    raise
                print(result.stdout, flush=True)
                expected = [
                    f'PASS: Peek stopwatch-{str(s).lower()}-paused-{str(p).lower()}-other-task-{str(t).lower()}'
                    for s, p, t in itertools.product([False, True], repeat=3)
                ]
                observed = [line for line in result.stdout.splitlines() if line.startswith('PASS: Peek ')]
                assert sorted(observed) == sorted(expected), f'Incomplete native peek matrix: {observed}'
                """#, temporary.path,
            ]
            process.currentDirectoryURL = temporary
            var environment = ProcessInfo.processInfo.environment
            environment["PERCH_DATA"] = temporary.appendingPathComponent("launcher-planner.json").path
            process.environment = environment
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let result = try String(contentsOf: log, encoding: .utf8)
            FileHandle.standardError.write(Data(result.utf8))
            XCTAssertEqual(process.terminationReason, .exit)
            XCTAssertEqual(process.terminationStatus, 0, "Native peek check failed:\n\(result)")
            for stopwatch in [false, true] {
                for paused in [false, true] {
                    for hasOtherTask in [false, true] {
                        let marker = "PASS: Peek stopwatch-\(stopwatch)-paused-\(paused)-other-task-\(hasOtherTask)"
                        XCTAssertEqual(result.components(separatedBy: "\n").filter { $0 == marker }.count, 1)
                    }
                }
            }
        }
    }
#endif
