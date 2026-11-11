import AppKit
import ApplicationServices
import SwiftUI
import XCTest
@testable import PerchApp
@testable import PlannerCore

/// Real native controls backed by a synthetic document, never the user's planner.
final class TaskDetailsViewTests: XCTestCase {
    @MainActor
    func testFooterStaysVisibleAndOutsideScrollingContentAtSmallSizes() async throws {
        let fixture = try DetailsFixture()
        defer { fixture.close() }
        for size in [NSSize(width: 280, height: 220), NSSize(width: 360, height: 320), NSSize(width: 460, height: 600)]
        {
            let window = Self.makeWindow(size: size)
            let host = NSHostingView(
                rootView: TaskDetailsSheet(taskID: fixture.task.id)
                    .environmentObject(fixture.store)
                    // XCTest is not an assistive client. Materialize SwiftUI's
                    // real AX elements without changing system permissions.
                    .environment(\.accessibilityEnabled, true))
            window.contentView = host
            window.setContentSize(size)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            defer { window.close() }
            let save = try await Self.control("details-save", in: window)
            let cancel = try await Self.control("details-cancel", in: window)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.bounds.width, size.width, accuracy: 1)
            XCTAssertEqual(host.bounds.height, size.height, accuracy: 1)
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
            await Self.settle()
            let liveSave = try await Self.control("details-save", in: window)
            let liveCancel = try await Self.control("details-cancel", in: window)
            XCTAssertEqual(Self.frame(liveSave), saveFrame)
            XCTAssertEqual(Self.frame(liveCancel), cancelFrame)
            XCTAssertEqual(try fixture.file.load().tasks[0], fixture.task)
        }
    }

    @MainActor
    func testCancelDiscardsNativeTitleEditAndDismissesWithoutWrites() async throws {
        let fixture = try DetailsFixture()
        defer { fixture.close() }
        let before = try fixture.snapshot()
        let sheet = try await fixture.present()
        try await Self.editTitle("Discard this edit", in: sheet)
        XCTAssertEqual(try fixture.file.load().tasks[0], fixture.task)
        try Self.press(try await Self.control("details-cancel", in: sheet))
        try await fixture.assertDismissed()
        XCTAssertEqual(try fixture.snapshot(), before, "Cancel must not write even identical bytes or sidecars")
    }

    @MainActor
    func testEscapeDiscardsNativeTitleEditAndDismissesWithoutWrites() async throws {
        let fixture = try DetailsFixture()
        defer { fixture.close() }
        let before = try fixture.snapshot()
        let sheet = try await fixture.present()
        try await Self.editTitle("Discard with Escape", in: sheet)
        // A native key-equivalent dispatch, not a call to the view's Cancel closure.
        // editTitle verifies the field editor identity before relinquishing focus.
        sheet.makeKeyAndOrderFront(nil)
        XCTAssertTrue(sheet.isKeyWindow)
        let escape = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertTrue(sheet.performKeyEquivalent(with: escape), "The real Cancel shortcut handles Escape")
        try await fixture.assertDismissed()
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    @MainActor
    func testSavePersistsNativeTitleEditAndDismisses() async throws {
        let fixture = try DetailsFixture()
        defer { fixture.close() }
        let sheet = try await fixture.present()
        try await Self.editTitle("Saved checklist title", in: sheet)
        XCTAssertEqual(try fixture.file.load().tasks[0].title, fixture.task.title)
        try Self.press(try await Self.control("details-save", in: sheet))
        try await fixture.assertDismissed()
        let saved = try fixture.file.load().tasks[0]
        XCTAssertEqual(saved.title, "Saved checklist title", "Positive control: native editing must reach the draft")
        XCTAssertEqual(saved.notes, fixture.task.notes)
        fixture.store.undo()
        XCTAssertEqual(try fixture.file.load().tasks[0], fixture.task, "Save is one undoable transaction")
    }

    @MainActor
    func testRemovedTaskKeepsAnOperableCloseControl() async throws {
        let fixture = try DetailsFixture()
        defer { fixture.close() }
        let sheet = try await fixture.present()
        _ = try await Self.control("details-cancel", in: sheet)
        XCTAssertNotNil(fixture.store.send(.delete(fixture.task.id)))
        XCTAssertTrue(try fixture.file.load().tasks.isEmpty)
        let afterDelete = try fixture.snapshot()
        let close = try await Self.control("details-close", in: sheet)
        XCTAssertTrue(fixture.presentation.isPresented)
        try Self.press(close)
        try await fixture.assertDismissed()
        XCTAssertEqual(try fixture.snapshot(), afterDelete, "Closing an unavailable task performs no further writes")
    }

    @MainActor
    private static func editTitle(_ title: String, in window: NSWindow) async throws {
        _ = try await control("details-title", role: "AXTextField", in: window)
        let field = try XCTUnwrap(
            window.contentView.flatMap { root in
                views(root).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Task title" }
            })
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === editor, "Keyboard edits target the actual title field")
        editor.insertText(title, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertEqual(editor.string, title)
        XCTAssertTrue(window.makeFirstResponder(nil))
        await settle()
        XCTAssertEqual(field.stringValue, title)
    }

    @MainActor
    fileprivate static func makeWindow(size: NSSize) -> NSWindow {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        // A borderless, non-key host need not appear in AXWindows. Match an ordinary editor window.
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor
    fileprivate static func settle() async { try? await Task.sleep(nanoseconds: 100_000_000) }

    @MainActor
    fileprivate static func control(_ identifier: String, role: String = "AXButton", in window: NSWindow) async throws
        -> NSObject
    {
        // Waking the AX client is asynchronous; one immediate lookup can precede SwiftUI's tree publication.
        var wakeResult = "not queried"
        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            wakeResult = await wakeAccessibility()
            await settle()
            if let node = nodes(window).first(where: {
                attribute($0, "accessibilityIdentifier") as? String == identifier
                    && attribute($0, "accessibilityRole") as? String == role
            }) {
                return node
            }
        }
        let observed = nodes(window).map {
            "\(attribute($0, "accessibilityRole") ?? "?")/\(attribute($0, "accessibilityIdentifier") ?? "?")/\(attribute($0, "accessibilityLabel") ?? "?")"
        }.joined(separator: "\n")
        XCTFail("Missing \(identifier) (\(role)) in native window; AX query: \(wakeResult); observed:\n\(observed)")
        throw DetailsTestError.missingControl
    }

    private static func wakeAccessibility() async -> String {
        await Task.detached {
            let app = AXUIElementCreateApplication(getpid())
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            let windows = (value as? [AXUIElement]) ?? []
            var results = ["windows=\(result.rawValue):\(windows.count)"]
            for window in windows {
                var children: CFTypeRef?
                let childResult = AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children)
                results.append("children=\(childResult.rawValue):\((children as? [AXUIElement])?.count ?? 0)")
            }
            return results.joined(separator: " ")
        }.value
    }

    @MainActor private static func press(_ node: NSObject) throws {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let implementation = try XCTUnwrap(node.responds(to: selector) ? node.method(for: selector) : nil)
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(
            unsafeBitCast(implementation, to: Press.self)(node, selector), "The native control accepts its AX press")
    }

    @MainActor private static func attribute(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
    }

    @MainActor private static func nodes(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        @MainActor func walk(_ node: NSObject, _ depth: Int) -> [NSObject] {
            guard depth < 60, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            var children = (attribute(node, "accessibilityChildren") as? [NSObject]) ?? []
            // Ignored hosting containers may omit native descendants from their AX children.
            if let view = node as? NSView { children += view.subviews }
            if let window = node as? NSWindow, let content = window.contentView { children.append(content) }
            return [node] + children.flatMap { walk($0, depth + 1) }
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

private enum DetailsTestError: Error { case missingControl, missingSheet }

@MainActor
private final class DetailsPresentation: ObservableObject {
    @Published var isPresented = false
}

@MainActor
private struct DetailsPresenter: View {
    @ObservedObject var presentation: DetailsPresentation
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
private final class DetailsFixture {
    let directory: URL
    let file: PlannerFile
    let task: PlanTask
    let store: PlannerStore
    let window: NSWindow
    let presentation = DetailsPresentation()
    let activationPolicy: NSApplication.ActivationPolicy

    init() throws {
        activationPolicy = NSApplication.shared.activationPolicy()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directory = root
        file = PlannerFile(url: root.appendingPathComponent("planner.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        task = PlanTask(
            title: "Review the synthetic checklist", day: DayKey(now), createdAt: now,
            notes: String(repeating: "A long note for scrolling. ", count: 30),
            steps: (1...12).map { Subtask(title: "Checklist step \($0)") })
        var planner = Planner()
        planner.preferences.resetHour = 0
        planner.tasks = [task]
        try file.save(planner)
        store = PlannerStore(file: file, now: { now }, watching: false)
        window = TaskDetailsViewTests.makeWindow(size: NSSize(width: 640, height: 780))
        window.contentView = NSHostingView(
            rootView: DetailsPresenter(presentation: presentation, store: store, taskID: task.id))
    }

    func present() async throws -> NSWindow {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await TaskDetailsViewTests.settle()
        presentation.isPresented = true
        for _ in 0..<20 {
            await TaskDetailsViewTests.settle()
            if let sheet = window.attachedSheet {
                _ = try await TaskDetailsViewTests.control("details-save", in: sheet)
                return sheet
            }
        }
        XCTFail("The real SwiftUI sheet must be presented before testing dismissal")
        throw DetailsTestError.missingSheet
    }

    func assertDismissed() async throws {
        for _ in 0..<20 {
            if !presentation.isPresented && window.attachedSheet == nil { return }
            await TaskDetailsViewTests.settle()
        }
        XCTAssertFalse(presentation.isPresented)
        XCTAssertNil(window.attachedSheet)
    }

    func snapshot() throws -> [String: String] {
        var result: [String: String] = [:]
        let entries = try XCTUnwrap(
            FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]))
        for case let url as URL in entries {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            if values.isRegularFile == true {
                result[url.path] =
                    "\(values.contentModificationDate!.timeIntervalSince1970):\(try Data(contentsOf: url).base64EncodedString())"
            }
        }
        return result
    }

    func close() {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.close()
        NSApp.setActivationPolicy(activationPolicy)
        try? FileManager.default.removeItem(at: directory)
    }
}
