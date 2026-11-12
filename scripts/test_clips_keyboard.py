"""Portable controls for the Clips keyboard fixture, NOT native UI validation.

Compile the probe's actual helpers against data-only adapters. AppKit event
routing, SwiftUI focus registration and menu tracking still require macOS.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "scripts/clips_layout_probe.swift").read_text()


def section(start, end):
    return SOURCE[SOURCE.index(start):SOURCE.index(end, SOURCE.index(start))]


ASSERTIONS = section("    let clipsKeyboardAssertions = [", "    @MainActor\n    private final class ClipsKeyboardPasteboard")
RUN = section("    struct ClipsKeyboardFailure:", "    /// The ordered assertion set;")
NODES = "@MainActor\n" + section("func clipsNodes(", "\n@MainActor\nfunc clipsNames(")
FOCUS = "@MainActor\n" + section("    func clipsKeyboardNodes(", "    @MainActor\n    func writeClipsKeyboardState(")
STATE = "@MainActor\n" + section("    func writeClipsKeyboardState(", "    @MainActor\n    func clipsTabUntil(")
TAB = "@MainActor\n" + section("    func clipsTabUntil(", "    /// Observes one native menu")
EVENT = "@MainActor\n" + section("    func clipsKeyEvent(", "    @MainActor\n    func clipsKeySettle(")

# Only the framework interfaces are substituted; the graph walk and focus
# identity decisions above are compiled from the native probe unchanged.
NODE_ADAPTER = r'''
import Foundation
@MainActor class ProbeNode {
    var attributes: [String: Any] = [:]
    var names: [String] = []
    var focused: Bool? = false
    func responds(to selector: String) -> Bool { focused != nil }
}
@MainActor class NSView: ProbeNode {
    var subviews: [NSView] = []
    var bounds = CGRect(x: 0, y: 0, width: 800, height: 400)
    var acceptsFirstResponder = true
    var isHiddenOrHasHiddenAncestor = false
    var visibleRect: CGRect { bounds }
}
@MainActor final class NSWindow: ProbeNode {
    var contentView: NSView? = NSView()
    var firstResponder: ProbeNode?
    var isKeyWindow = true
    var isVisible = true
}
let NSApp = ProbeNode()
@MainActor func clipsAttribute(_ node: ProbeNode, _ name: String) -> Any? {
    node.attributes[name]
}
@MainActor func clipsNames(_ node: ProbeNode) -> [String] { node.names }
func NSSelectorFromString(_ value: String) -> String { value }
@MainActor func clipsBool(_ node: ProbeNode, _ name: String) -> Bool {
    name == "isAccessibilityFocused" && node.focused == true
}
func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: message, code: 1) }
}
'''


class ClipsKeyboardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.swift = shutil.which("swiftc")
        if cls.swift is None:
            raise AssertionError("swiftc is required for Clips keyboard adapter controls")

    def compile_run(self, program):
        swift = self.swift
        assert swift is not None
        # Honor the caller's approved evidence/TMPDIR location; never use /tmp
        # when an evidence location was supplied by the task runner.
        with tempfile.TemporaryDirectory(prefix="clips-keyboard-", dir=os.environ.get("TMPDIR")) as directory:
            main = Path(directory) / "main.swift"
            main.write_text(program)
            binary = Path(directory) / "controls"
            compiled = subprocess.run(
                [swift, "-swift-version", "6", str(main), "-o", str(binary)],
                capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            return subprocess.run([str(binary)], cwd=directory, capture_output=True, text=True, timeout=30)

    def test_all_19_assertions_keep_their_exact_identity_and_fail_closed(self):
        names = re.findall(r'^\s*"((?:week|clips):[^"\n]+)",', ASSERTIONS, re.M)
        self.assertEqual(len(names), 19)
        self.assertEqual(len(set(names)), 19)
        self.assertEqual(sum(name.startswith("week:") for name in names), 9)
        self.assertEqual(sum(name.startswith("clips:") for name in names), 10)
        program = "import Foundation\n" + RUN + ASSERTIONS + r'''
for name in clipsKeyboardAssertions {
    let run = ClipsKeyboardRun(broken: name, evidenceDirectory: URL(fileURLWithPath: "/unused"))
    precondition(run.breaks(name))
    precondition(!run.breaks("unrelated assertion"))
    try run.require(true, "fixture")
    var caught = false
    do {
        try run.require(false, name, "deliberate failure")
    } catch let failure as ClipsKeyboardFailure {
        caught = true
        precondition(failure.assertion == name && failure.detail == "deliberate failure")
    }
    precondition(caught && run.passed == ["fixture"])
    try run.require(true, name)
    precondition(run.passed == ["fixture", name])
    run.record(name)
    precondition(run.trace == [name])
}
print("19 assertion identities and failure controls passed")
'''
        result = self.compile_run(program)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("19 assertion identities and failure controls passed", result.stdout)
        self.assertEqual(result.stderr.count("Clips keyboard: "), 19)

    def test_event_payloads_preserve_down_up_and_each_native_key(self):
        adapter = r'''
import Foundation
struct NSEvent {
    enum EventType { case keyDown, keyUp }
    struct ModifierFlags: OptionSet { let rawValue: UInt }
    let type: EventType
    let modifierFlags: ModifierFlags
    let windowNumber: Int
    let characters: String
    let charactersIgnoringModifiers: String
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
'''
        checks = r'''
for type in [NSEvent.EventType.keyDown, .keyUp] {
    for (code, text) in [(UInt16(48), "\t"), (49, " "), (53, "\u{1b}"), (36, "\r"), (125, "\u{f701}")] {
        let event = try clipsKeyEvent(code, text, type: type, windowNumber: 17)
        precondition(event.type == type && event.windowNumber == 17 && event.keyCode == code)
        precondition(event.characters == text && event.charactersIgnoringModifiers == text)
        precondition(!event.isARepeat && event.modifierFlags.isEmpty)
    }
}
print("event payload controls passed")
'''
        result = self.compile_run(adapter + RUN + EVENT + checks)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("event payload controls passed", result.stdout)

    def test_focus_graph_and_direct_getters_reject_false_missing_and_wrong_identity(self):
        checks = r'''
let window = NSWindow()
let root = window.contentView!
let target = ProbeNode()
target.attributes["accessibilityIdentifier"] = "menu-target"
target.names = ["Actions for exact clip"]
target.focused = true
let other = ProbeNode()
other.attributes["accessibilityIdentifier"] = "menu-target-other"
other.focused = true
window.firstResponder = other
// A graph cycle and duplicate paths must not duplicate the same native node.
root.attributes["accessibilityChildren"] = [other]
other.attributes["accessibilityContents"] = [root]
root.attributes["accessibilityChildrenInNavigationOrder"] = [target, other]
try expect(!clipsNodes(root).contains { $0 === target }, "layout traversal must remain unchanged")
try expect(clipsKeyboardNodes(window).filter { $0 === target }.count == 1, "navigation-order target")
try expect(clipsIsFocused(window, "menu-target"), "exact identifier")
try expect(clipsIsFocused(window, "Actions for exact clip"), "exact label")
try expect(!clipsIsFocused(window, "menu"), "partial identity must not pass")
root.attributes.removeValue(forKey: "accessibilityChildrenInNavigationOrder")
// Each public owner can expose a focused element omitted from its child tree.
for owner in [NSApp, window, root, other] {
    owner.attributes["accessibilityFocusedUIElement"] = target
    try expect(clipsIsFocused(window, "menu-target"), "direct focused-element getter")
    try expect(clipsFocusedNames(window).contains("menu-target|Actions for exact clip"), "trace direct focus")
    owner.attributes.removeValue(forKey: "accessibilityFocusedUIElement")
}
try expect(!clipsIsFocused(window, "menu-target"), "absent target")
root.attributes["accessibilityChildren"] = [target, other]
NSApp.attributes["accessibilityFocusedUIElement"] = target
window.attributes["accessibilityFocusedUIElement"] = target
try expect(clipsKeyboardNodes(window).filter { $0 === target }.count == 1, "deduplicate owners and children")
for state in [Optional(false), Optional<Bool>.none] {
    target.focused = state
    try expect(!clipsIsFocused(window, "menu-target"), "target's own native focus required")
}
target.focused = true
window.isKeyWindow = false
try expect(!clipsIsFocused(window, "menu-target"), "key window required")
window.isKeyWindow = true
window.contentView = nil
try expect(!clipsIsFocused(window, "menu-target"), "live content required")
print("focus graph controls passed")
'''
        actual = (NODES + FOCUS).replace("NSObject", "ProbeNode")
        variants = {
            "correct": actual,
            "omit_navigation_order": actual.replace("includingNavigationOrder: true", "includingNavigationOrder: false"),
            "omit_direct_focus": actual.replace("nodes.append(focused)", "_ = focused"),
            "omit_key_window_guard": actual.replace("guard window.isKeyWindow else { return false }", ""),
            "omit_native_focus_guard": actual.replace('&& clipsBool(node, "isAccessibilityFocused")', ""),
            "omit_deduplication": actual.replace(
                "return nodes.filter { seen.insert(ObjectIdentifier($0)).inserted }", "return nodes"),
        }
        for name, code in variants.items():
            with self.subTest(variant=name):
                if name != "correct":
                    self.assertNotEqual(code, actual, "Negative control must actually mutate the helper")
                result = self.compile_run(NODE_ADAPTER + code + checks)
                if name == "correct":
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("focus graph controls passed", result.stdout)
                else:
                    self.assertNotEqual(result.returncode, 0, "Broken focus observation passed")
                    self.assertNotIn("focus graph controls passed", result.stdout)

    def test_tab_loop_keeps_30_key_budget_negative_controls_and_evidence_order(self):
        adapter = r'''
var keyCount = 0
var settleCount = 0
var observations: [String] = []
var revealOnKey = false
let target = ProbeNode()
@MainActor func clipsKey(_ window: NSWindow, _ code: UInt16, _ text: String) async throws {
    precondition(code == 48 && text == "\t")
    keyCount += 1
    observations.append("key")
    if revealOnKey {
        target.focused = true
        window.attributes["accessibilityFocusedUIElement"] = target
    }
}
@MainActor func clipsKeySettle() async { settleCount += 1 }
@MainActor func writeClipsKeyboardState(_ window: NSWindow, target: String, to url: URL) throws {
    observations.append(url.lastPathComponent)
}
@MainActor func capture(_ host: NSView, size: CGSize, to url: URL) throws {
    observations.append(url.lastPathComponent)
}
let window = NSWindow()
let assertion = clipsKeyboardAssertions[0]
target.attributes["accessibilityIdentifier"] = "menu-target"
for mode in ["reachable", "missing", "withheld"] {
    keyCount = 0; settleCount = 0; observations = []
    target.focused = false
    window.attributes.removeValue(forKey: "accessibilityFocusedUIElement")
    revealOnKey = mode == "reachable"
    let run = ClipsKeyboardRun(broken: mode == "withheld" ? assertion : nil,
                               evidenceDirectory: URL(fileURLWithPath: "/unused"))
    var failure: ClipsKeyboardFailure?
    do { try await clipsTabUntil(window, "menu-target", run: run, assertion: assertion) }
    catch let caught as ClipsKeyboardFailure { failure = caught }
    try expect(observations.first == "tab-0.before.json", "diagnostics before keys")
    try expect(observations[1] == "tab-0.before.png", "capture before keys")
    try expect(observations.last == "tab-0.after.json", "diagnostics before failure")
    if mode == "reachable" {
        try expect(failure == nil && run.passed == [assertion] && keyCount == 1, "real key prerequisite")
    } else {
        try expect(failure?.assertion == assertion && run.passed.isEmpty, "exact failure preserved")
        try expect(keyCount == (mode == "missing" ? 30 : 0), "Tab budget and withholding preserved")
        try expect(settleCount == (mode == "withheld" ? 30 : 0), "negative control remains bounded")
    }
}
print("Tab traversal adapter controls passed")
'''
        program = NODE_ADAPTER + RUN + ASSERTIONS + (NODES + FOCUS + TAB).replace("NSObject", "ProbeNode") + adapter
        result = self.compile_run(program)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Tab traversal adapter controls passed", result.stdout)

    def test_diagnostics_preserve_unnamed_native_focus_and_target_metadata(self):
        checks = r'''
@MainActor func clipsFrame(_ node: ProbeNode, in host: NSView) throws -> CGRect { host.bounds }
let window = NSWindow()
let root = window.contentView!
let unnamed = NSView()
unnamed.focused = true
unnamed.attributes["accessibilityRole"] = "AXTextField"
window.firstResponder = unnamed
window.attributes["accessibilityFocusedUIElement"] = unnamed
let missing = ProbeNode()
missing.attributes["accessibilityIdentifier"] = "menu-target"
missing.focused = nil
root.attributes["accessibilityChildrenInNavigationOrder"] = [missing]
let url = URL(fileURLWithPath: "state.json")
try writeClipsKeyboardState(window, target: "menu-target", to: url)
let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
try expect(result["target"] as? String == "menu-target", "retain target")
try expect(result["keyWindow"] as? Bool == true, "retain key status")
try expect(!(result["firstResponderClass"] as! String).isEmpty, "retain unnamed native responder")
let rows = result["nodes"] as! [[String: Any]]
let focused = rows.filter { $0["focused"] as? Bool == true }
try expect(focused.count == 1 && focused[0]["role"] as? String == "AXTextField", "retain anonymous focus role")
let absent = rows.first { $0["identifier"] as? String == "menu-target" }!
try expect(absent["hasFocusGetter"] as? Bool == false, "missing getter is distinct from unfocused")
try expect(absent["focused"] as? Bool == false, "missing getter cannot report focus")
print("diagnostic schema controls passed")
'''
        code = (NODES + FOCUS + STATE).replace("NSObject", "ProbeNode")
        result = self.compile_run(NODE_ADAPTER + code + checks)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("diagnostic schema controls passed", result.stdout)

    def test_host_and_native_event_path_are_not_replaced_by_model_actions(self):
        window = section("    func clipsKeyboardWindow(", "    @MainActor\n    func clipsKeyboardWeek(")
        self.assertIn(r"view.environment(\.accessibilityEnabled, true)", window)
        self.assertLess(window.index("host.sizingOptions = []"), window.index("window.contentView = host"))
        key = section("    func clipsKey(_ window:", "    @MainActor\n    func clipsBool(")
        self.assertIn("[NSEvent.EventType.keyDown, .keyUp]", key)
        self.assertIn("NSApp.sendEvent(try clipsKeyEvent", key)
        self.assertIn("NSApp.postEvent(event, atStart: false)", SOURCE)
        self.assertNotIn("makeFirstResponder", TAB)
        self.assertNotIn("accessibilityPerformPress", TAB)
        self.assertNotIn("Task.sleep", TAB)
        self.assertIn("window.isKeyWindow && destinations.before.currentEditor() === window.firstResponder", SOURCE)
        # A source regression guard complements, but does not replace, native runs.
        for index in range(19):
            if index in (0, 9, 12):
                self.assertTrue(f"run: run, assertion: clipsKeyboardAssertions[{index}]" in SOURCE,
                                f"Missing Tab negative control for assertion {index}")
            else:
                self.assertTrue(f"run.breaks(clipsKeyboardAssertions[{index}])" in SOURCE,
                                f"Missing negative control for assertion {index}")
        self.assertTrue('let ok = broken == nil ? red == nil : red?.assertion == broken' in SOURCE)


if __name__ == "__main__":
    unittest.main()
