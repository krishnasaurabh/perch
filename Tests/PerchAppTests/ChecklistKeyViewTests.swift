#if os(macOS)
    import AppKit
    @testable import PerchApp
    import PerchUI
    import SwiftUI
    import XCTest

    /// Unit fixtures control activation; the frozen app probe checks real desktop key-window ownership.
    @MainActor
    private final class ChecklistTestWindow: NSWindow {
        var reportsKeyWindow = true
        override var isKeyWindow: Bool { reportsKeyWindow }
    }

    final class ChecklistKeyViewTests: XCTestCase {
        @MainActor
        private func event(
            _ code: UInt16, in window: NSWindow, characters: String = "\t",
            type: NSEvent.EventType = .keyDown, flags: NSEvent.ModifierFlags = [], repeated: Bool = false
        ) -> NSEvent {
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: repeated, keyCode: code)!
        }

        @MainActor
        func testActualResponderIsTheSingleSemanticGroupAndTabLeavesIt() async {
            _ = NSApplication.shared
            let window = ChecklistTestWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let before = NSTextField(frame: NSRect(x: 20, y: 240, width: 200, height: 24))
            let group = ChecklistKeyView(frame: NSRect(x: 20, y: 90, width: 200, height: 130))
            let after = NSTextField(frame: NSRect(x: 20, y: 40, width: 200, height: 24))
            group.active = true
            group.setAccessibilityIdentifier("today-checklist")
            root.addSubview(before); root.addSubview(group); root.addSubview(after)
            window.contentView = root
            window.autorecalculatesKeyViewLoop = false
            before.nextKeyView = group; group.nextKeyView = after; after.nextKeyView = before
            @MainActor
            func responderState(_ stage: String) -> String {
                let responder = window.firstResponder
                let responderClass = responder.map { String(reflecting: type(of: $0)) } ?? "nil"
                return "\(stage): firstResponder=\(responderClass), "
                    + "isGroup=\(responder === group), isBeforeEditor=\(responder === before.currentEditor()), "
                    + "isAfterEditor=\(responder === after.currentEditor()), "
                    + "groupCanBecomeKeyView=\(group.canBecomeKeyView), windowIsKey=\(window.isKeyWindow)"
            }
            @MainActor
            func logResponder(_ stage: String) {
                FileHandle.standardError.write(Data((responderState(stage) + "\n").utf8))
            }
            window.orderFront(nil)
            logResponder("after orderFront")
            XCTAssertTrue(group.canBecomeKeyView, responderState("group must be a key view"))
            XCTAssertTrue(window.makeFirstResponder(before), responderState("focus before field"))
            logResponder("after makeFirstResponder(before)")
            XCTAssertFalse(group.isAccessibilityFocused(), responderState("before entering group"))
            // Text fields install a field editor as the window's actual first responder.
            window.selectNextKeyView(before)
            logResponder("after selectNextKeyView(window.firstResponder)")
            XCTAssertTrue(window.firstResponder === group, responderState("Tab must enter the single checklist stop"))
            XCTAssertTrue(group.isAccessibilityFocused(), responderState("entered checklist must report AX focus"))
            window.reportsKeyWindow = false
            XCTAssertFalse(group.isAccessibilityFocused(), responderState("non-key window must not report AX focus"))
            XCTAssertTrue(
                window.firstResponder === group, responderState("non-key window must retain checklist responder"))
            window.reportsKeyWindow = true
            XCTAssertTrue(
                (group.accessibilityFocusedUIElement as? NSView) === group,
                responderState("focused AX element must be the checklist group itself"))
            group.keyDown(with: event(48, in: window))
            XCTAssertTrue(
                window.firstResponder === after.currentEditor(), responderState("Tab must leave for after field editor")
            )
            XCTAssertFalse(group.isAccessibilityFocused(), responderState("Tab departure must clear AX focus"))
            XCTAssertNil(
                group.accessibilityFocusedUIElement, responderState("Tab departure must clear focused AX element"))
            window.selectPreviousKeyView(after)
            XCTAssertTrue(window.firstResponder === group, responderState("Shift-Tab must re-enter checklist"))
            group.keyDown(with: event(48, in: window, flags: .shift))
            XCTAssertTrue(
                window.firstResponder === before.currentEditor(),
                responderState("Shift-Tab must leave for before field editor"))
            XCTAssertFalse(group.isAccessibilityFocused(), responderState("Shift-Tab departure must clear AX focus"))
        }

        @MainActor
        func testTabRepeatAndKeyUpCannotAdvanceTwiceAndInactiveGroupIsSkipped() async {
            _ = NSApplication.shared
            let window = ChecklistTestWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let group = ChecklistKeyView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
            window.contentView = group
            group.active = true
            var directions: [Bool] = []
            group.tab = {
                directions.append($0); return true
            }
            group.keyDown(with: event(48, in: window))
            group.keyDown(with: event(48, in: window, repeated: true))
            group.keyUp(with: event(48, in: window, type: .keyUp))
            group.keyDown(with: event(48, in: window, flags: .shift))
            XCTAssertEqual(directions, [false, true])
            group.active = false
            XCTAssertFalse(group.acceptsFirstResponder)
            XCTAssertFalse(group.canBecomeKeyView)
            XCTAssertFalse(group.isAccessibilityFocused())
            group.removeFromSuperview()
            XCTAssertFalse(group.acceptsFirstResponder)
        }

        @MainActor
        func testNativeCommandDispatchUsesTheExistingPhaseAndModifierContract() async {
            _ = NSApplication.shared
            let window = ChecklistTestWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let group = ChecklistKeyView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
            window.contentView = group
            group.active = true
            window.orderFront(nil)
            XCTAssertTrue(window.makeFirstResponder(group))
            var presses: [ChecklistKeyPress] = []
            group.key = {
                presses.append($0); return .handled
            }
            XCTAssertTrue(group.performKeyEquivalent(with: event(40, in: window, characters: "k", flags: .command)))
            group.keyDown(with: event(49, in: window, characters: " ", repeated: true))
            group.keyUp(with: event(49, in: window, characters: " ", type: .keyUp))
            group.keyDown(with: event(126, in: window, characters: "\u{F700}", flags: .option))
            XCTAssertEqual(presses.count, 4)
            XCTAssertEqual(presses[0].characters, "k")
            XCTAssertEqual(presses[0].modifiers, .command)
            XCTAssertEqual(presses[0].phase, .down)
            XCTAssertEqual(presses[1].key, .space)
            XCTAssertEqual(presses[1].phase, .repeat)
            XCTAssertEqual(presses[2].phase, .up)
            XCTAssertEqual(presses[3].key, .upArrow)
            XCTAssertEqual(presses[3].modifiers, .option)
            group.active = false
            XCTAssertFalse(window.firstResponder === group)
            XCTAssertFalse(group.isAccessibilityFocused())
        }

        @MainActor
        func testViewportMarkerResolvesSiblingScrollerAndRejectsAmbiguity() async {
            _ = NSApplication.shared
            let window = ChecklistTestWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 351),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 351))
            window.contentView = root
            let marker = NSView(frame: NSRect(x: 30, y: 120, width: 302, height: 137))
            let list = NSScrollView(frame: marker.frame)
            list.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 302, height: 1200))
            let notepad = NSScrollView(frame: NSRect(x: 376, y: 28, width: 165, height: 54))
            notepad.documentView = NSTextView(frame: notepad.bounds)
            root.addSubview(list); root.addSubview(notepad); root.addSubview(marker)
            XCTAssertNil(marker.enclosingScrollView)
            XCTAssertTrue(ChecklistViewportAttachment.resolve(from: marker) === list)
            let duplicate = NSScrollView(frame: marker.frame)
            duplicate.documentView = NSView(frame: duplicate.bounds)
            root.addSubview(duplicate)
            XCTAssertNil(ChecklistViewportAttachment.resolve(from: marker))
            duplicate.isHidden = true
            XCTAssertTrue(ChecklistViewportAttachment.resolve(from: marker) === list)
            marker.frame.origin.x += 20
            XCTAssertNil(ChecklistViewportAttachment.resolve(from: marker))
            marker.removeFromSuperview()
            XCTAssertNil(ChecklistViewportAttachment.resolve(from: marker))
        }
    }
#endif
