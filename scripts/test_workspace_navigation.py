"""Portable failure controls for the native workspace probe, not UI execution."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class WorkspaceProbeTests(unittest.TestCase):
    def test_assertions_reject_missing_focus_targets_and_ring_pixels(self):
        source = (ROOT / "Tests/PerchAppTests/WorkspaceBandProbe.swift").read_text()
        helpers = source.split("private func failure(", 1)[1].split("/// Called only", 1)[0]
        program = """
import Foundation
private enum WorkspaceNavigationError: Error {
    case assertion(String, String, UInt)
}
private func failure(""" + helpers + """
private func rejects(_ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw WorkspaceNavigationError.assertion("Negative control passed", #fileID, #line)
}
try require(true)
try requireFalse(false)
try requireEqual("selected", "selected")
try requireEqual(Double(2), Double(2.5), accuracy: 1)
try requireEqual(CGFloat(2), CGFloat(2.5), accuracy: 1)
try requireAtLeast(CGFloat(28), CGFloat(28))
try requireAtLeast(CGFloat(28), Double(28))
try requireEqual(CGFloat(2), Double(2), accuracy: 1)
try requireGreater(CGFloat(1), CGFloat(0))
try requireNil(Optional<Int>.none)
try requireEqual(try unwrap(Optional(1)), 1)
try rejects { try require(false, "Missing native focus") }
try rejects { try requireFalse(true, "Focus stolen") }
try rejects { try requireEqual("Not selected", "Selected") }
try rejects { try requireEqual(Double(0), Double(2), accuracy: 1) }
try rejects { try requireEqual(CGFloat(0), CGFloat(2), accuracy: 1) }
try rejects { try requireEqual(Double.nan, Double(2), accuracy: 1) }
try rejects { try requireAtLeast(CGFloat(26), CGFloat(28)) }
try rejects { try requireGreater(CGFloat(0), CGFloat(0)) }
try rejects { try requireNil(Optional(1)) }
try rejects { _ = try unwrap(Optional<Int>.none) }
print("Workspace assertion positive and negative controls passed")
"""
        with tempfile.TemporaryDirectory() as directory:
            main = pathlib.Path(directory) / "main.swift"
            main.write_text(program)
            swift = shutil.which("swiftc")
            if swift is None:
                self.fail("Swift must be available to verify the native assertion helpers")
            binary = pathlib.Path(directory) / "assertion-controls"
            subprocess.run([swift, str(main), "-o", str(binary)], check=True, capture_output=True, text=True)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn("positive and negative controls passed", result.stdout)

    def test_tab_event_characters_and_reject_either_forward_tab_field(self):
        source = (ROOT / "Tests/PerchAppTests/WorkspaceBandProbe.swift").read_text()
        constructor = source.split("@MainActor\nprivate func workspaceKeyEvent(", 1)[1].split("private func failure(", 1)[0]
        helpers = source.split("private func failure(", 1)[1].split("/// Called only", 1)[0]
        # Compile the actual event constructor with a data-only NSEvent adapter.
        # The native preflight and UI traversal separately exercise real AppKit.
        adapter = r"""
import Foundation
private struct NSEvent {
    enum EventType { case keyDown, keyUp }
    struct ModifierFlags: OptionSet, Sendable {
        let rawValue: UInt
        static let shift = Self(rawValue: 1 << 17)
    }
    let type: EventType
    let modifierFlags: ModifierFlags
    let windowNumber: Int
    let characters: String?
    let charactersIgnoringModifiers: String?
    let isARepeat: Bool
    let keyCode: UInt16
    static func keyEvent(
        with type: EventType, location: CGPoint, modifierFlags: ModifierFlags,
        timestamp: TimeInterval, windowNumber: Int, context: Int?,
        characters: String, charactersIgnoringModifiers: String,
        isARepeat: Bool, keyCode: UInt16
    ) -> NSEvent? {
        Self(type: type, modifierFlags: modifierFlags, windowNumber: windowNumber,
             characters: characters, charactersIgnoringModifiers: charactersIgnoringModifiers,
             isARepeat: isARepeat, keyCode: keyCode)
    }
}
private enum WorkspaceNavigationError: Error {
    case assertion(String, String, UInt)
}
"""
        checks = r"""
for type in [NSEvent.EventType.keyDown, .keyUp] {
    for flags in [NSEvent.ModifierFlags(), .shift] {
        let event = try workspaceKeyEvent(48, "\t", type: type, modifiers: flags, windowNumber: 7)
        let expected = flags.contains(.shift) ? "\u{19}" : "\t"
        try requireEqual(event.characters, expected, "characters payload")
        try requireEqual(event.charactersIgnoringModifiers, expected, "unmodified payload")
        try requireEqual(event.type, type)
        try requireEqual(event.modifierFlags, flags)
        try requireEqual(event.windowNumber, 7)
        try requireEqual(event.keyCode, 48)
        try requireFalse(event.isARepeat)
        try requireEqual(event.characters == "\t", !flags.contains(.shift))
    }
    // Shift must not turn a different key into back-tab.
    let other = try workspaceKeyEvent(49, " ", type: type, modifiers: .shift, windowNumber: 7)
    try requireEqual(other.characters, " ")
    try requireEqual(other.charactersIgnoringModifiers, " ")
}
print("Tab event construction controls passed")
"""
        variants = {
            "correct": constructor,
            "forward_characters": constructor.replace("characters: eventCharacters,", "characters: characters,"),
            "forward_ignoring_modifiers": constructor.replace(
                "charactersIgnoringModifiers: eventCharacters,", "charactersIgnoringModifiers: characters,"),
            "missing_shift_translation": constructor.replace('"\\u{19}" : characters', '"\\t" : characters'),
        }
        swift = shutil.which("swiftc")
        if swift is None:
            self.fail("Swift is required to verify event construction")
        with tempfile.TemporaryDirectory() as directory:
            for name, body in variants.items():
                with self.subTest(name=name):
                    if name != "correct":
                        self.assertNotEqual(body, constructor, "Negative control must mutate the constructor")
                    main = pathlib.Path(directory) / "main.swift"
                    main.write_text(adapter + "\n@MainActor\nprivate func workspaceKeyEvent(" + body
                                    + "private func failure(" + helpers + checks)
                    binary = pathlib.Path(directory) / name
                    compiled = subprocess.run(
                        [swift, "-swift-version", "6", str(main), "-o", str(binary)],
                        capture_output=True, text=True,
                    )
                    self.assertEqual(compiled.returncode, 0, compiled.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True)
                    if name == "correct":
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertIn("Tab event construction controls passed", result.stdout)
                    else:
                        self.assertNotEqual(result.returncode, 0, "Malformed forward-Tab payload passed")
                        self.assertNotIn("Tab event construction controls passed", result.stdout)

    def test_roving_focus_lifecycle_with_delayed_native_registration(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WorkspaceView.swift").read_text()
        methods = source.split("    private func selectPage(", 1)[1].split("    private struct WorkspacePageStyle", 1)[0]
        # Compile production state transitions unchanged. The fake native focus
        # rejects requests until a target is registered, but is not SwiftUI/AppKit.
        program = """
import Foundation
private enum NotchPage: CaseIterable { case home, week; static let workspacePages: [NotchPage] = [.home, .week] }
private enum KeyPress { enum Result { case ignored, handled } }
@MainActor private enum Motion {
    enum Token { case pop }
    static func token(_ value: Token) -> Int { 1 }
    static func animate(_ value: Int, policy: Int, _ action: () -> Void) { action() }
}
@MainActor private final class Model { var page = NotchPage.home }
@MainActor private final class Window { var isKeyWindow = true }
@MainActor private final class Anchor { var window: Window? = Window() }
@MainActor private final class FocusLifecycle {
    let model = Model()
    let moreAnchor = Anchor()
    var enabled = true
    let motionPolicy = 0
    var pageGroupHasFocus = false
    var registeredPage = NotchPage.home
    var rejectedFocusRequests = 0
    var nativeFocus: NotchPage?
    var focusedPage: NotchPage? {
        get { nativeFocus }
        set {
            if let newValue, newValue != registeredPage {
                rejectedFocusRequests += 1
                nativeFocus = nil
            } else {
                nativeFocus = newValue
            }
        }
    }
    private func selectPage(""" + methods + """
    func enter() {
        registeredPage = model.page
        let old = focusedPage
        focusedPage = model.page
        pageFocusChanged(from: old, to: focusedPage)
        precondition(pageGroupHasFocus)
    }
    func renderSelection() {
        let old = focusedPage
        registeredPage = model.page
        if old != registeredPage {
            nativeFocus = nil
            pageFocusChanged(from: old, to: nil)
        }
        restorePageFocus(model.page)
    }
    func settle() async throws { try await Task.sleep(nanoseconds: 10_000_000) }
    func run() async throws {
        // Passive selection never asks native focus to move.
        selectPage(.week)
        renderSelection()
        try await settle()
        precondition(nativeFocus == nil && !pageGroupHasFocus)
        selectPage(.home)
        renderSelection()
        enter()

        // Keys change selection only; render-time handoff retains group ownership
        // across the temporary nil and waits for native registration.
        for (step, expected) in [(1, NotchPage.week), (-1, .home), (1, .week)] {
            let old = model.page
            precondition(movePage(from: old, by: step) == .handled)
            precondition(model.page == expected && nativeFocus == old)
            renderSelection()
            precondition(nativeFocus == nil && pageGroupHasFocus)
            try await settle()
            precondition(nativeFocus == expected && rejectedFocusRequests == 0)
        }
        for page in [NotchPage.week, .home] {
            precondition(focusPage(page) == .handled)
            renderSelection()
            try await settle()
            precondition(nativeFocus == page)
        }
        precondition(movePage(from: .home, by: -1) == .handled)
        precondition(nativeFocus == .home)
        _ = focusPage(.week)
        renderSelection()
        try await settle()
        precondition(movePage(from: .week, by: 1) == .handled)
        precondition(nativeFocus == .week)

        // Both Tab directions use the same unconsumed handler. A queued request
        // cannot pull focus back from More or a preceding text field.
        for _ in 0..<2 {
            enter()
            _ = focusPage(.home)
            renderSelection()
            precondition(leavePageGroup() == .ignored)
            nativeFocus = nil
            try await settle()
            precondition(nativeFocus == nil && !pageGroupHasFocus)
            _ = focusPage(.week)
            renderSelection()
            try await settle()
            precondition(nativeFocus == nil)
        }

        // Multiple selections before dispatch reject the stale destination.
        enter()
        _ = focusPage(.week)
        renderSelection()
        _ = focusPage(.week)
        renderSelection()
        try await settle()
        precondition(nativeFocus == .week && rejectedFocusRequests == 0)

        // Leaving without a page change clears ownership. A non-key window and
        // a disabled picker also reject pending requests.
        pageFocusChanged(from: .week, to: nil)
        nativeFocus = nil
        precondition(!pageGroupHasFocus)
        for disabled in [false, true] {
            enter()
            _ = focusPage(model.page == .home ? .week : .home)
            renderSelection()
            if disabled { enabled = false } else { moreAnchor.window?.isKeyWindow = false }
            try await settle()
            precondition(nativeFocus == nil)
            enabled = true
            moreAnchor.window?.isKeyWindow = true
        }
        enabled = false
        let previous = model.page
        precondition(focusPage(.week) == .ignored && model.page == previous)
        precondition(rejectedFocusRequests == 0)
        print("Roving focus lifecycle adapter checks passed")
    }
}
try await FocusLifecycle().run()
"""
        with tempfile.TemporaryDirectory() as directory:
            main = pathlib.Path(directory) / "main.swift"
            main.write_text(program)
            swift = shutil.which("swiftc")
            if swift is None:
                self.fail("Swift is required to verify focus lifecycle transitions")
            binary = pathlib.Path(directory) / "focus-lifecycle"
            compiled = subprocess.run(
                [swift, "-swift-version", "6", str(main), "-o", str(binary)], capture_output=True, text=True,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Roving focus lifecycle adapter checks passed", result.stdout)

    def test_more_menu_routes_actions_and_clears_retained_callbacks(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WorkspaceView.swift").read_text()
        anchor = source.split("@MainActor\nprivate final class WorkspaceMenuAnchorView", 1)[1].split("struct IDBox:", 1)[0]
        # Adapt only Objective-C dispatch; this is not an AppKit runtime test.
        anchor = anchor.replace("#selector(performMenuAction(_:))", '"performMenuAction:"').replace("@objc ", "")
        program = """
import Foundation
// The extracted view uses app localization; keep the routing adapter standalone.
@MainActor private enum AppL10n {
    static var requestedKeys: [String] = []
    static func text(_ key: String) -> String {
        requestedKeys.append(key)
        return key
    }
}
@MainActor private class NSView {
    var window: Int? = 1
    var bounds = CGRect(x: 0, y: 0, width: 35, height: 30)
    var isFlipped: Bool { false }
    func isAccessibilityElement() -> Bool { true }
}
@MainActor private final class NSMenuItem {
    let title: String
    weak var target: AnyObject?
    var tag = 0
    var isEnabled = true
    init(title: String, action: String?, keyEquivalent: String) { self.title = title }
    static func separator() -> NSMenuItem { NSMenuItem(title: "", action: nil, keyEquivalent: "") }
}
@MainActor private final class NSMenu {
    static var popup: ((NSMenu, CGPoint, NSView) -> Void)?
    let title: String
    var autoenablesItems = true
    var items: [NSMenuItem] = []
    init(title: String) { self.title = title }
    func addItem(_ item: NSMenuItem) { items.append(item) }
    func popUp(positioning: NSMenuItem?, at point: CGPoint, in view: NSView) {
        precondition(positioning == nil)
        Self.popup?(self, point, view)
    }
}
@MainActor private final class WorkspaceMenuAnchorView""" + anchor + """
extension WorkspaceMenuAnchorView {
    func activate(_ item: NSMenuItem) { performMenuAction(item) }
}
private let view = WorkspaceMenuAnchorView()
private var calls = [0, 0, 0, 0, 0]
private var retained: [NSMenuItem] = []
precondition(!view.isAccessibilityElement())
precondition(view.isFlipped)
for enabled in [false, true] {
    NSMenu.popup = { menu, point, owner in
        precondition(owner === view)
        precondition(point == CGPoint(x: 0, y: 30))
        precondition(menu.title == "More" && !menu.autoenablesItems)
        precondition(menu.items.map(\\.title) == ["Your week", "History", "Projects", "Settings", "Keys"])
        precondition(menu.items[4].isEnabled == enabled)
        precondition(menu.items.prefix(4).allSatisfy(\.isEnabled))
        retained = menu.items
        for item in menu.items where !item.title.isEmpty && item.isEnabled {
            view.activate(item)
        }
    }
    view.show(keysAvailable: enabled, yourWeek: { calls[0] += 1 },
              history: { calls[1] += 1 }, projects: { calls[2] += 1 },
              settings: { calls[3] += 1 }, keys: { calls[4] += 1 })
}
precondition(calls == [2, 2, 2, 2, 1])
for item in retained { view.activate(item) }
precondition(calls == [2, 2, 2, 2, 1], "Menu callbacks must not outlive tracking")
view.window = nil
NSMenu.popup = { _, _, _ in preconditionFailure("Unattached anchors cannot present") }
view.show(keysAvailable: true, yourWeek: { calls[0] += 1 },
          history: { calls[1] += 1 }, projects: { calls[2] += 1 },
          settings: { calls[3] += 1 }, keys: { calls[4] += 1 })
precondition(calls == [2, 2, 2, 2, 1])
precondition(AppL10n.requestedKeys == ["Your week", "History", "Projects", "Settings", "Keys",
                                      "Your week", "History", "Projects", "Settings", "Keys"])
print("Menu routing and lifetime adapter checks passed")
"""
        with tempfile.TemporaryDirectory() as directory:
            main = pathlib.Path(directory) / "main.swift"
            main.write_text(program)
            swift = shutil.which("swiftc")
            if swift is None:
                self.fail("Swift is required to verify menu routing")
            binary = pathlib.Path(directory) / "menu-routing"
            compiled = subprocess.run(
                [swift, "-swift-version", "6", str(main), "-o", str(binary)], capture_output=True, text=True,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn("Menu routing and lifetime adapter checks passed", result.stdout)

    def test_runner_rejects_non_macos_before_building(self):
        with tempfile.TemporaryDirectory() as directory:
            uname = pathlib.Path(directory) / "uname"
            uname.write_text("#!/bin/sh\nprintf '%s\\n' Linux\n")
            uname.chmod(0o755)
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/check_workspace_navigation.sh"), directory],
                env=dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"]),
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("requires macOS", result.stderr)
            self.assertFalse((pathlib.Path(directory) / "planner.json").exists())


if __name__ == "__main__":
    unittest.main()
