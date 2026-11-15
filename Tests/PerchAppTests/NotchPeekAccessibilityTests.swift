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
                    let host = NSHostingView(
                        rootView: NotchPeekView()
                            .environmentObject(store).environmentObject(model)
                            .environment(\.accessibilityEnabled, true)
                            .environment(\.motionPolicyOverride, MotionPolicy(reduceMotion: true)))
                    let window = NSWindow(
                        contentRect: NSRect(
                            x: 0, y: 0, width: NotchPeekLayout.width, height: NotchPeekLayout.contentHeight),
                        styleMask: [.titled], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    defer { window.close() }
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    await Self.primeAccessibility()
                    try await Task.sleep(for: .milliseconds(250))
                    host.layoutSubtreeIfNeeded()
                    let all = nodes(window)
                    let labels = all.compactMap { string($0, "accessibilityLabel") }
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
