import AppKit
import ApplicationServices
import SwiftUI
import XCTest
@testable import PerchApp
@testable import PlannerCore

/// Native geometry checks use only a synthetic document and an isolated host window.
final class TaskDetailsViewTests: XCTestCase {
    @MainActor
    func testFooterStaysVisibleAndOutsideScrollingContentAtSmallSizes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let file = PlannerFile(url: directory.appendingPathComponent("planner.json"))
        var planner = Planner()
        let task = PlanTask(
            title: "Review the synthetic checklist", day: DayKey(now), createdAt: now,
            notes: String(repeating: "A long note for scrolling. ", count: 30),
            steps: (1...12).map { Subtask(title: "Checklist step \($0)") })
        planner.tasks = [task]
        try file.save(planner)
        let store = PlannerStore(file: file, now: { now }, watching: false)
        _ = NSApplication.shared
        for size in [NSSize(width: 280, height: 220), NSSize(width: 360, height: 320), NSSize(width: 460, height: 600)]
        {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: TaskDetailsSheet(taskID: task.id).environmentObject(store))
            host.frame = NSRect(origin: .zero, size: size)
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(nanoseconds: 150_000_000)
            await Self.wakeAccessibility()
            host.layoutSubtreeIfNeeded()
            let nodes = Self.nodes(host)
            let save = try XCTUnwrap(
                nodes.first { Self.attribute($0, "accessibilityIdentifier") as? String == "details-save" })
            let cancel = try XCTUnwrap(
                nodes.first { Self.attribute($0, "accessibilityIdentifier") as? String == "details-cancel" })
            XCTAssertEqual(Self.attribute(save, "accessibilityRole") as? String, "AXButton")
            let saveFrame = Self.frame(save), cancelFrame = Self.frame(cancel)
            let visible = window.convertToScreen(host.convert(host.bounds, to: nil))
            XCTAssertGreaterThan(saveFrame.width, 0)
            XCTAssertGreaterThan(cancelFrame.height, 0)
            XCTAssertTrue(visible.insetBy(dx: -1, dy: -1).contains(saveFrame), "Save stays fully inside the small host")
            XCTAssertTrue(
                visible.insetBy(dx: -1, dy: -1).contains(cancelFrame), "Cancel stays fully inside the small host")
            XCTAssertFalse(saveFrame.intersects(cancelFrame))
            let scroll = try XCTUnwrap(
                Self.views(host).compactMap { $0 as? NSScrollView }.max {
                    ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0)
                })
            XCTAssertGreaterThan(scroll.documentView?.bounds.height ?? 0, scroll.contentSize.height)
            let viewport = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
            XCTAssertFalse(
                viewport.insetBy(dx: 1, dy: 1).intersects(saveFrame), "The scrolling form reserves the footer")
            let bottom = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentSize.height)
            scroll.documentView?.scroll(NSPoint(x: 0, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(nanoseconds: 50_000_000)
            let afterScroll = Self.nodes(host)
            let liveSave = try XCTUnwrap(
                afterScroll.first { Self.attribute($0, "accessibilityIdentifier") as? String == "details-save" })
            let liveCancel = try XCTUnwrap(
                afterScroll.first { Self.attribute($0, "accessibilityIdentifier") as? String == "details-cancel" })
            XCTAssertEqual(Self.frame(liveSave), saveFrame)
            XCTAssertEqual(Self.frame(liveCancel), cancelFrame)
            XCTAssertEqual(try file.load().tasks[0], task)
        }
    }

    private static func wakeAccessibility() async {
        await Task.detached {
            let app = AXUIElementCreateApplication(getpid())
            var value: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            for window in (value as? [AXUIElement]) ?? [] {
                var children: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children)
            }
        }.value
    }

    @MainActor private static func attribute(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
    }

    @MainActor private static func nodes(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        @MainActor func walk(_ node: NSObject, _ depth: Int) -> [NSObject] {
            guard depth < 60, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            return [node]
                + ((attribute(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap { walk($0, depth + 1) }
        }
        return walk(root, 0)
    }

    @MainActor private static func frame(_ node: NSObject) -> NSRect {
        guard node.responds(to: NSSelectorFromString("accessibilityFrame")),
            let value = node.value(forKey: "accessibilityFrame") as? NSValue
        else { return .zero }
        return value.rectValue
    }

    @MainActor private static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
}
