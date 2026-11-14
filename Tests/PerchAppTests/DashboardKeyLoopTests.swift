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
        let selection = DashboardSelection(tab: .history)
        let tabHost = DashboardTabsHost(selection: selection, environment: EnvironmentValues())
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
    func testEverySectionInstallsInitialTabStopWithoutRequiringSearch() async throws {
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        for section in DashboardView.Tab.allCases {
            let selection = DashboardSelection(tab: section)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let root = NSView(frame: window.contentLayoutRect)
            let host = DashboardTabsHost(selection: selection, environment: EnvironmentValues())
            host.frame = NSRect(x: 20, y: 450, width: 280, height: 30)
            let action = NSButton(title: "Page action", target: nil, action: nil)
            action.frame = NSRect(x: 20, y: 350, width: 150, height: 30)
            root.addSubview(host)
            root.addSubview(action)
            window.contentView = root
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<30 {
                root.layoutSubtreeIfNeeded()
                if DashboardKeyLoop.tabKeyView(in: window) != nil { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            for _ in 0..<2 {
                DashboardKeyLoop.install(in: window)
                let tabs = try XCTUnwrap(DashboardKeyLoop.tabKeyView(in: window))
                XCTAssertTrue(window.initialFirstResponder === tabs)
                XCTAssertTrue(root.nextKeyView === tabs)
                XCTAssertTrue(tabs.nextValidKeyView === action, Self.keyLoopDiagnostic(window, phase: section.rawValue))
            }
        }
    }

    @MainActor
    func testArrowAndSpaceUseCurrentSelectionAndDoNotStealPageKeys() async throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let selection = DashboardSelection()
        let host = DashboardTabsHost(selection: selection, environment: EnvironmentValues())
        host.frame = NSRect(x: 20, y: 450, width: 280, height: 30)
        let root = NSView(frame: window.contentLayoutRect)
        let action = NSButton(title: "Page action", target: nil, action: nil)
        action.frame = NSRect(x: 20, y: 350, width: 150, height: 30)
        root.addSubview(host)
        root.addSubview(action)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<30 {
            root.layoutSubtreeIfNeeded()
            if DashboardKeyLoop.tabKeyView(in: window) != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        func event(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        for expected in [DashboardView.Tab.history, .projects] {
            let tabs = try XCTUnwrap(DashboardKeyLoop.tabKeyView(in: window))
            XCTAssertTrue(window.makeFirstResponder(tabs))
            XCTAssertTrue(host.handleSelectionKey(event(124, "\u{f703}")))
            XCTAssertEqual(selection.tab, expected)
            // No run-loop yield between Right and Space: activation reads the model,
            // never the old SwiftUI Button closure from the preceding section.
            XCTAssertTrue(host.handleSelectionKey(event(49, " ")))
            XCTAssertEqual(selection.tab, expected)
        }
        XCTAssertTrue(window.makeFirstResponder(action))
        XCTAssertFalse(host.handleSelectionKey(event(123, "\u{f702}")))
        XCTAssertFalse(host.handleSelectionKey(event(49, " ")))
        XCTAssertEqual(selection.tab, .projects)
        let tabs = try XCTUnwrap(DashboardKeyLoop.tabKeyView(in: window))
        XCTAssertTrue(window.makeFirstResponder(tabs))
        XCTAssertFalse(host.handleSelectionKey(event(123, "\u{f702}", flags: .command)))
        XCTAssertEqual(selection.tab, .projects)
        XCTAssertTrue(host.moveFocus(backward: false))
        XCTAssertTrue(window.firstResponder === action)
        await Task.yield()
        XCTAssertTrue(window.firstResponder === action, "Leaving the strip must cancel deferred restoration")
    }

    @MainActor
    func testSelectionChangesPreserveHostedRootAndRefreshHistoryLinks() async throws {
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let selection = DashboardSelection()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: window.contentLayoutRect)
        let host = DashboardTabsHost(selection: selection, environment: EnvironmentValues())
        host.frame = NSRect(x: 20, y: 450, width: 280, height: 30)
        let search = DashboardSearchField(frame: NSRect(x: 20, y: 380, width: 280, height: 24))
        search.identifier = NSUserInterfaceItemIdentifier(DashboardKeyLoop.searchIdentifier)
        let action = NSButton(title: "Page action", target: nil, action: nil)
        action.frame = NSRect(x: 20, y: 350, width: 150, height: 30)
        root.addSubview(host)
        root.addSubview(action)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<30 {
            root.layoutSubtreeIfNeeded()
            if DashboardKeyLoop.tabKeyView(in: window) != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        selection.tab = .history
        root.addSubview(search)
        host.refreshKeyLoop()
        var tabs = try XCTUnwrap(DashboardKeyLoop.tabKeyView(in: window))
        XCTAssertTrue(tabs.nextKeyView === search)
        XCTAssertTrue(search.previousKeyView === tabs)
        search.removeFromSuperview()
        selection.tab = .projects
        host.refreshKeyLoop()
        tabs = try XCTUnwrap(DashboardKeyLoop.tabKeyView(in: window))
        XCTAssertTrue(window.initialFirstResponder === tabs)
        XCTAssertTrue(tabs.nextValidKeyView === action)
        XCTAssertFalse(tabs.nextKeyView === search)
        XCTAssertTrue(host.selectionState === selection)
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
