import AppKit
import ApplicationServices
import PerchUI
import PlannerCore
import SwiftUI
import XCTest
@testable import PerchApp

final class NotchPeekAccessibilityTests: XCTestCase {
    @MainActor
    func testStandaloneBlockKeepsItsTimeAndActionWithoutBorrowingTaskContent() async throws {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(policy) }
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
                        let task = try XCTUnwrap(store.addTasks(["Unrelated task"], on: .day(store.today))?.first)
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
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    await Self.primeAccessibility()
                    let all = try await publishedNodes(in: window, host: host)
                    let scenario = "stopwatch-\(stopwatch)-paused-\(paused)-other-task-\(hasOtherTask)"
                    try captureDiagnostics(all, in: window, host: host, scenario: scenario)
                    let labels = all.compactMap { string($0, "accessibilityLabel") }
                    XCTAssertEqual(host.bounds.size.width, size.width, accuracy: 1)
                    XCTAssertEqual(host.bounds.size.height, size.height, accuracy: 1)
                    XCTAssertEqual(all.filter { string($0, "accessibilityIdentifier") == "notch.peek.time" }.count, 1)
                    XCTAssertEqual(all.filter { string($0, "accessibilityIdentifier") == "notch.peek.block" }.count, 1)
                    XCTAssertFalse(labels.contains("Nothing planned yet"), "Found: \(labels)")
                    XCTAssertFalse(labels.contains { $0.contains("Unrelated") }, "Found: \(labels)")
                    let time = try XCTUnwrap(
                        all.first { string($0, "accessibilityIdentifier") == "notch.peek.time" }, "Found: \(labels)")
                    XCTAssertTrue(
                        string(time, "accessibilityLabel")?.hasSuffix(stopwatch ? " elapsed" : " left") == true,
                        "Found: \(labels)")
                    let button = try XCTUnwrap(
                        all.first { string($0, "accessibilityIdentifier") == "notch.peek.block" }, "Found: \(labels)")
                    XCTAssertEqual(string(button, "accessibilityLabel"), paused ? "Continue" : "Pause")
                    let selector = NSSelectorFromString("accessibilityPerformPress")
                    XCTAssertTrue(button.responds(to: selector))
                    let implementation = try XCTUnwrap(button.method(for: selector))
                    typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                    XCTAssertTrue(unsafeBitCast(implementation, to: Press.self)(button, selector))
                    try await Task.sleep(for: .milliseconds(200))
                    let saved = try file.load()
                    XCTAssertEqual(saved.focus?.state, paused ? .running : .paused)
                    XCTAssertNil(saved.focus?.taskID)
                    XCTAssertEqual(saved.tasks, tasks)
                }
            }
        }
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
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(scenario).png"))
    }

    private nonisolated static func primeAccessibility() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                let app = AXUIElementCreateApplication(getpid())
                var raw: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
                FileHandle.standardError.write(Data("Peek AX root priming: \(status.rawValue)\n".utf8))
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

    @MainActor private func value(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
    }

    @MainActor private func string(_ node: NSObject, _ name: String) -> String? {
        value(node, name) as? String
    }

    @MainActor private func nodes(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        var result: [NSObject] = []
        @MainActor func walk(_ node: NSObject, depth: Int) {
            guard depth < 40, seen.insert(ObjectIdentifier(node)).inserted else { return }
            result.append(node)
            var children = ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"]
                .flatMap { value(node, $0) as? [NSObject] ?? [] }
            if let view = node as? NSView { children += view.subviews }
            if let window = node as? NSWindow, let content = window.contentView { children.append(content) }
            for child in children { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return result
    }
}
