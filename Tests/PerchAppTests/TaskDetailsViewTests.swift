import AppKit
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
            Self.assertFooterOutsideViewport(scroll, controls: [saveFrame, cancelFrame], in: window)
            let originalOffset = scroll.contentView.bounds.origin
            let bottom = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentSize.height)
            scroll.documentView?.scroll(NSPoint(x: 0, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
            await Self.settle()
            let liveSave = try await Self.control("details-save", in: window)
            let liveCancel = try await Self.control("details-cancel", in: window)
            XCTAssertEqual(Self.frame(liveSave), saveFrame)
            XCTAssertEqual(Self.frame(liveCancel), cancelFrame)
            XCTAssertNotEqual(scroll.contentView.bounds.origin, originalOffset, "The form actually scrolled")
            Self.assertFooterOutsideViewport(
                scroll, controls: [Self.frame(liveSave), Self.frame(liveCancel)], in: window)
            XCTAssertEqual(try fixture.file.load().tasks[0], fixture.task)
        }
    }

    @MainActor
    func testDirectHostPublishesControlIdentifiers() async throws {
        let fixture = try DetailsFixture()
        defer { fixture.close() }
        let window = Self.makeWindow(size: NSSize(width: 460, height: 600))
        window.contentView = NSHostingView(
            rootView: TaskDetailsSheet(taskID: fixture.task.id).environmentObject(fixture.store)
                .environment(\.accessibilityEnabled, true))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        // AppKit-backed fields expose their placeholder, not the SwiftUI identifier.
        let title = try await Self.control("details-title", role: "AXTextField", in: window)
        let field = try XCTUnwrap(title as? NSTextField)
        XCTAssertTrue(field.isEditable)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === editor, "The title field holds focus when details open")
        _ = try await Self.identifierControl("details-save", in: window)
        _ = try await Self.identifierControl("details-cancel", in: window)
        let clear = try await Self.control("schedule-date-clear", in: window)
        let add = try await Self.control("deadline-date-add", in: window)
        XCTAssertEqual(Self.attribute(clear, "accessibilityRole") as? String, "AXButton")
        XCTAssertEqual(Self.attribute(add, "accessibilityRole") as? String, "AXButton")
        XCTAssertTrue(try Self.isEnabled(clear))
        XCTAssertTrue(try Self.isEnabled(add))
        let date = try await Self.control("schedule-date-text", role: "AXTextField", in: window)
        XCTAssertEqual((date as? NSTextField)?.placeholderString, "YYYY-MM-DD")
        XCTAssertNotNil(fixture.store.send(.delete(fixture.task.id)))
        _ = try await Self.identifierControl("details-close", in: window)
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
        // Hosted runners may deny key-window activation; the shortcut must still work.
        print("Escape dispatch: sheet.isKeyWindow=\(sheet.isKeyWindow)")
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
    func testPickerCancelDiscardsScheduleAndDeadlineChanges() async throws {
        let fixture = try DetailsFixture()
        defer { fixture.close() }
        let before = try fixture.snapshot()
        let sheet = try await fixture.present()
        try Self.press(try await Self.control("schedule-date-clear", in: sheet))
        try Self.press(try await Self.control("deadline-date-add", in: sheet))
        XCTAssertEqual(try fixture.file.load().tasks[0], fixture.task)
        try Self.press(try await Self.control("details-cancel", in: sheet))
        try await fixture.assertDismissed()
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    @MainActor
    func testPickerSaveCommitsScheduleAndDeadlineTogether() async throws {
        let fixture = try DetailsFixture()
        defer { fixture.close() }
        let sheet = try await fixture.present()
        try Self.press(try await Self.control("schedule-date-clear", in: sheet))
        try Self.press(try await Self.control("deadline-date-add", in: sheet))
        XCTAssertEqual(try fixture.file.load().tasks[0], fixture.task)
        try Self.press(try await Self.control("details-save", in: sheet))
        try await fixture.assertDismissed()
        let saved = try fixture.file.load().tasks[0]
        XCTAssertNil(saved.day)
        XCTAssertEqual(saved.deadline, fixture.task.day)
        XCTAssertEqual(saved.title, fixture.task.title)
        fixture.store.undo()
        XCTAssertEqual(try fixture.file.load().tasks[0], fixture.task)
    }

    @MainActor
    func testInvalidTypedDateDisablesSaveUntilCorrected() async throws {
        let fixture = try DetailsFixture()
        defer { fixture.close() }
        let before = try fixture.snapshot()
        let sheet = try await fixture.present()
        // Deadline has no date yet, so the schedule is the sole typed-date field.
        let fieldNode = try await Self.control("schedule-date-text", role: "AXTextField", in: sheet)
        let field = try XCTUnwrap(fieldNode as? NSTextField)
        XCTAssertTrue(field.isEditable)
        XCTAssertTrue(sheet.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(sheet.firstResponder === editor)
        editor.insertText("2028-02-30", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertTrue(sheet.makeFirstResponder(nil))
        await Self.settle()
        let disabledSave = try await Self.control("details-save", in: sheet)
        XCTAssertFalse(try Self.isEnabled(disabledSave))
        XCTAssertTrue(fixture.presentation.isPresented)
        XCTAssertEqual(try fixture.snapshot(), before)
        XCTAssertTrue(sheet.makeFirstResponder(field))
        let correction = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let nextDay = try XCTUnwrap(fixture.task.day).adding(days: 1, calendar: fixture.store.engine.calendar)
        correction.insertText(
            nextDay.raw, replacementRange: NSRange(location: 0, length: correction.string.utf16.count))
        XCTAssertTrue(sheet.makeFirstResponder(nil))
        await Self.settle()
        let enabledSave = try await Self.control("details-save", in: sheet)
        XCTAssertTrue(try Self.isEnabled(enabledSave))
        try Self.press(enabledSave)
        try await fixture.assertDismissed()
        XCTAssertEqual(try fixture.file.load().tasks[0].day, nextDay)
    }

    @MainActor
    private static func editTitle(_ title: String, in window: NSWindow) async throws {
        let node = try await control("details-title", role: "AXTextField", in: window)
        let field = try XCTUnwrap(node as? NSTextField)
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
        // Native editing requires an ordinary key-capable editor window.
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
        try await lookup(identifier, role: role, in: window, requireIdentifier: false)
    }

    @MainActor
    private static func identifierControl(_ identifier: String, role: String = "AXButton", in window: NSWindow)
        async throws
        -> NSObject
    {
        try await lookup(identifier, role: role, in: window, requireIdentifier: true)
    }

    @MainActor
    private static func lookup(_ identifier: String, role: String, in window: NSWindow, requireIdentifier: Bool)
        async throws
        -> NSObject
    {
        let names = [
            "details-title": "Task title", "details-save": "Save", "details-cancel": "Cancel", "details-close": "Close",
            "schedule-date-clear": "Clear schedule", "deadline-date-add": "Add deadline",
            "schedule-date-text": "YYYY-MM-DD", "deadline-date-text": "YYYY-MM-DD",
        ]
        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            await settle()
            let candidates = nodes(window)
            if !requireIdentifier, let name = names[identifier] {
                // Native controls in a presented sheet may not inherit SwiftUI identifiers.
                // Use their real semantic properties, never positions or an arbitrary first field.
                if role == "AXTextField",
                    let field = candidates.compactMap({ $0 as? NSTextField }).first(where: {
                        $0.isEditable && $0.placeholderString == name
                    })
                {
                    return field
                }
                if role == "AXButton",
                    let button = candidates.compactMap({ $0 as? NSButton }).first(where: {
                        $0.accessibilityRole() == .button
                            && ($0.title == name || $0.accessibilityLabel() == name)
                    })
                {
                    print(
                        "Resolved \(identifier): native \(type(of: button)) "
                            + "role=\(button.accessibilityRole()?.rawValue ?? "nil") "
                            + "label=\(button.accessibilityLabel() ?? "nil") "
                            + "id=\(button.accessibilityIdentifier() ?? "nil") enabled=\(button.isEnabled)")
                    return button
                }
            }
            if let node = candidates.first(where: {
                attribute($0, "accessibilityIdentifier") as? String == identifier
                    && attribute($0, "accessibilityRole") as? String == role
            }) {
                return node
            }
            if !requireIdentifier, let name = names[identifier],
                let node = candidates.first(where: {
                    attribute($0, "accessibilityRole") as? String == role
                        && (attribute($0, "accessibilityLabel") as? String == name
                            || attribute($0, "accessibilityTitle") as? String == name)
                })
            {
                return node
            }
        }
        let observed = nodes(window).map { node in
            let native: String
            if let button = node as? NSButton {
                native = "title=\(button.title)"
            } else if let field = node as? NSTextField {
                native = "placeholder=\(field.placeholderString ?? "nil")"
            } else {
                native = ""
            }
            return "\(type(of: node)) role=\(attribute(node, "accessibilityRole") ?? "?") "
                + "id=\(attribute(node, "accessibilityIdentifier") ?? "?") "
                + "label=\(attribute(node, "accessibilityLabel") ?? "?") \(native) "
                + "accessibilityAttributeNames=\(attribute(node, "accessibilityAttributeNames") ?? "unavailable")"
        }.joined(separator: "\n")
        XCTFail("Missing \(identifier) (\(role), identifier required: \(requireIdentifier)); observed:\n\(observed)")
        throw DetailsTestError.missingControl
    }

    @MainActor private static func isEnabled(_ node: NSObject) throws -> Bool {
        if let button = node as? NSButton { return button.isEnabled }
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        let implementation = try XCTUnwrap(node.responds(to: selector) ? node.method(for: selector) : nil)
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(implementation, to: Getter.self)(node, selector)
    }

    @MainActor private static func press(_ node: NSObject) throws {
        XCTAssertEqual(attribute(node, "accessibilityRole") as? String, "AXButton")
        if let button = node as? NSButton {
            XCTAssertTrue(button.isEnabled, "The native button must be enabled")
            button.performClick(nil)
            return
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let implementation = try XCTUnwrap(node.responds(to: selector) ? node.method(for: selector) : nil)
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(
            unsafeBitCast(implementation, to: Press.self)(node, selector), "The native control accepts its AX press")
    }

    @MainActor
    private static func assertFooterOutsideViewport(_ scroll: NSScrollView, controls: [NSRect], in window: NSWindow) {
        let clip = window.convertToScreen(scroll.contentView.convert(scroll.contentView.visibleRect, to: nil))
        let outer = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
        let insets = scroll.contentInsets
        // Insets are measured from the scroll view, not subtracted a second time
        // from an already-inset clip view. Screen coordinates increase upwards.
        let insetOuter = NSRect(
            x: outer.minX + insets.left, y: outer.minY + insets.bottom,
            width: max(0, outer.width - insets.left - insets.right),
            height: max(0, outer.height - insets.top - insets.bottom))
        let viewport = clip.intersection(insetOuter)
        XCTAssertGreaterThan(viewport.width, 0, "The form has a real visible viewport")
        XCTAssertGreaterThan(viewport.height, 0, "The form must not be collapsed to hide overlap")
        for control in controls {
            XCTAssertFalse(
                viewport.insetBy(dx: 1, dy: 1).intersects(control),
                "The scrolling form reserves the footer: clip=\(clip), insets=\(insets), control=\(control)")
        }
    }

    @MainActor private static func attribute(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
    }

    @MainActor private static func nodes(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        @MainActor func walk(_ node: NSObject, _ depth: Int) -> [NSObject] {
            guard depth < 60, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            // Scroll areas expose their hosted content through AXContents; walking
            // only AXChildren misses the SwiftUI elements within the native scroller.
            var children = ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"]
                .flatMap { (attribute(node, $0) as? [NSObject]) ?? [] }
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
