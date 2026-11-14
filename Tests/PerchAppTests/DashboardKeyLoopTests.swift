import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import PerchApp

final class DashboardKeyLoopTests: XCTestCase {
    @MainActor
    func testHistorySearchHasExplicitTabPredecessor() async throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
        func tabContent() -> AnyView {
            AnyView(
                PerchSegmented(
                    title: "Section", items: DashboardView.Tab.allCases.map { ($0, $0.rawValue) },
                    selection: .constant(.history), surface: .sheet
                ).id(UUID()).environment(\.accessibilityEnabled, true))
        }
        let tabHost = DashboardTabsHost(rootView: tabContent())
        tabHost.frame = NSRect(x: 20, y: 450, width: 280, height: 30)
        let search = DashboardSearchField(frame: NSRect(x: 20, y: 380, width: 280, height: 24))
        search.identifier = NSUserInterfaceItemIdentifier(DashboardKeyLoop.searchIdentifier)
        search.isEditable = true
        let agent = NSPopUpButton(frame: NSRect(x: 320, y: 380, width: 150, height: 24))
        agent.addItem(withTitle: "All agents")
        root.addSubview(tabHost)
        root.addSubview(search)
        root.addSubview(agent)
        window.contentView = root
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        window.makeKeyAndOrderFront(nil)
        let backtab = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .shift,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{19}", charactersIgnoringModifiers: "\u{19}", isARepeat: false, keyCode: 48)!
        let tab = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        for phase in ["initial", "rebuilt"] {
            if phase == "rebuilt" { tabHost.rootView = tabContent() }
            for _ in 0..<30 {
                root.layoutSubtreeIfNeeded()
                if DashboardKeyLoop.tabKeyView(in: window) != nil { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            // Recalculation can change SwiftUI's current native key view. Resolve
            // it after installation, never retain the pre-installation candidate.
            for _ in 0..<2 {
                DashboardKeyLoop.install(in: window)
                let tabs = try XCTUnwrap(DashboardKeyLoop.tabKeyView(in: window))
                let diagnostic = Self.keyLoopDiagnostic(window, phase: phase)
                XCTAssertTrue(tabs.nextKeyView === search, diagnostic)
                XCTAssertTrue(search.previousKeyView === tabs, diagnostic)
                XCTAssertNotNil(search.nextKeyView, diagnostic)
                XCTAssertFalse(search.nextKeyView === search, diagnostic)
            }
            XCTAssertTrue(window.makeFirstResponder(search))
            let editor = try XCTUnwrap(search.currentEditor())
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertTrue(search.handleNavigation(backtab))
            let currentTabs = try XCTUnwrap(DashboardKeyLoop.tabKeyView(in: window))
            XCTAssertTrue(window.firstResponder === currentTabs, Self.keyLoopDiagnostic(window, phase: phase))
            // A key after leaving the search must not be consumed by its monitor.
            XCTAssertFalse(search.handleNavigation(backtab))
            XCTAssertTrue(window.makeFirstResponder(search))
            // Also preserve forward navigation out of the field editor.
            XCTAssertTrue(search.handleNavigation(tab))
            XCTAssertNil(search.currentEditor())
            XCTAssertNotNil(window.firstResponder)
            XCTAssertFalse(search.handleNavigation(tab))
        }
    }

    @MainActor
    private static func keyLoopDiagnostic(_ window: NSWindow, phase: String) -> String {
        func identity(_ object: AnyObject?) -> String {
            guard let object else { return "nil" }
            return "\(type(of: object))@\(ObjectIdentifier(object))"
        }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let views = window.contentView.map(descendants) ?? []
        let links = views.filter { $0.canBecomeKeyView || $0 is DashboardTabsHost }.prefix(100).map { view in
            "\(identity(view)) previous=\(identity(view.previousKeyView)) next=\(identity(view.nextKeyView))"
        }.joined(separator: "\n")
        return "\(phase): first=\(identity(window.firstResponder)) "
            + "tabs=\(identity(DashboardKeyLoop.tabKeyView(in: window)))\n\(links)"
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
