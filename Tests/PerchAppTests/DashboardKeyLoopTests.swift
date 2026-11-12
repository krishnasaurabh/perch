import AppKit
import Foundation
import XCTest

@testable import PerchApp

final class DashboardKeyLoopTests: XCTestCase {
    @MainActor
    func testHistorySearchHasExplicitTabPredecessor() async {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
        let tabs = NSSegmentedControl(
            labels: DashboardView.Tab.allCases.map(\.rawValue), trackingMode: .selectOne, target: nil, action: nil)
        tabs.frame = NSRect(x: 20, y: 450, width: 420, height: 28)
        let search = DashboardSearchField(frame: NSRect(x: 20, y: 380, width: 280, height: 24))
        search.identifier = NSUserInterfaceItemIdentifier(DashboardKeyLoop.searchIdentifier)
        search.isEditable = true
        let agent = NSPopUpButton(frame: NSRect(x: 320, y: 380, width: 150, height: 24))
        agent.addItem(withTitle: "All agents")
        root.addSubview(tabs)
        root.addSubview(search)
        root.addSubview(agent)
        window.contentView = root
        DashboardKeyLoop.install(in: window)
        XCTAssertTrue(tabs.nextKeyView === search)
        XCTAssertTrue(search.previousKeyView === tabs)
        XCTAssertNotNil(search.nextKeyView)
        // Filtering rebuilds the page. Installing twice must not sever back-tab.
        DashboardKeyLoop.install(in: window)
        XCTAssertTrue(search.previousKeyView === tabs)
        XCTAssertFalse(search.nextKeyView === search)
        XCTAssertTrue(window.makeFirstResponder(search))
        XCTAssertTrue(window.firstResponder === search.currentEditor())
        let backtab = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .shift,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{19}", charactersIgnoringModifiers: "\u{19}", isARepeat: false, keyCode: 48)!
        XCTAssertTrue(search.handleNavigation(backtab))
        XCTAssertTrue(window.firstResponder === tabs)
        // A key after leaving the search must not be consumed by its monitor.
        XCTAssertFalse(search.handleNavigation(backtab))
    }

    @MainActor
    func testWeekKeyboardTargetRejectsAmbiguousOrDetachedLaunchers() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = root
        let target = WeekMenuKeyboardTarget()
        XCTAssertNil(target.popup())
        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 28, height: 28))
        root.addSubview(anchor)
        target.anchor = anchor
        XCTAssertNil(target.popup())
        let button = NSPopUpButton(frame: anchor.frame)
        root.addSubview(button)
        XCTAssertTrue(target.popup() === button)
        let other = NSPopUpButton(frame: anchor.frame)
        root.addSubview(other)
        XCTAssertNil(target.popup())
        other.isHidden = true
        XCTAssertTrue(target.popup() === button)
        button.isEnabled = false
        XCTAssertNil(target.popup())
    }

    @MainActor
    func testNativeSearchPublishesTypedQuery() async {
        let field = DashboardSearchField(frame: .zero)
        var observed = ""
        field.onChange = { observed = $0 }
        field.stringValue = "alpha"
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(observed, "alpha")
        XCTAssertTrue(field.delegate === field)
    }

    @MainActor
    func testDetachedSearchDoesNotConsumeNavigationOrTextCommands() async {
        let field = DashboardSearchField(frame: .zero)
        let editor = NSTextView(frame: .zero)
        XCTAssertFalse(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        XCTAssertFalse(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertFalse(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    }
}
