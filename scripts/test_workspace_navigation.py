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
        source = (ROOT / "scripts/workspace_navigation_probe.swift").read_text()
        helpers = source.split("private func failure(", 1)[1].split("let application =", 1)[0]
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

    def test_more_menu_routes_actions_and_clears_retained_callbacks(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WorkspaceView.swift").read_text()
        anchor = source.split("@MainActor\nprivate final class WorkspaceMenuAnchorView", 1)[1].split("struct IDBox:", 1)[0]
        # Adapt only Objective-C dispatch; this is not an AppKit runtime test.
        anchor = anchor.replace("#selector(performMenuAction(_:))", '"performMenuAction:"').replace("@objc ", "")
        program = """
import Foundation
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
private var calls = [0, 0, 0]
private var retained: [NSMenuItem] = []
precondition(!view.isAccessibilityElement())
precondition(view.isFlipped)
for enabled in [false, true] {
    NSMenu.popup = { menu, point, owner in
        precondition(owner === view)
        precondition(point == CGPoint(x: 0, y: 30))
        precondition(menu.title == "More" && !menu.autoenablesItems)
        precondition(menu.items.map(\\.title) == ["Undo", "", "Open Dashboard", "Settings…"])
        precondition(menu.items[0].isEnabled == enabled)
        precondition(menu.items[2].isEnabled && menu.items[3].isEnabled)
        retained = menu.items
        for item in menu.items where !item.title.isEmpty && item.isEnabled {
            view.activate(item)
        }
    }
    view.show(canUndo: enabled, undo: { calls[0] += 1 },
              dashboard: { calls[1] += 1 }, settings: { calls[2] += 1 })
}
precondition(calls == [1, 2, 2])
for item in retained { view.activate(item) }
precondition(calls == [1, 2, 2], "Menu callbacks must not outlive tracking")
view.window = nil
NSMenu.popup = { _, _, _ in preconditionFailure("Unattached anchors cannot present") }
view.show(canUndo: true, undo: { calls[0] += 1 },
          dashboard: { calls[1] += 1 }, settings: { calls[2] += 1 })
precondition(calls == [1, 2, 2])
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
