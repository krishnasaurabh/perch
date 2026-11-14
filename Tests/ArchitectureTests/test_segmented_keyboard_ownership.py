"""The same native segment must own keyboard and accessibility focus."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
PROBE = ROOT / "Tests/PerchAppTests/SegmentedKeyboardTests.swift"
COMPONENT = ROOT / "Sources/PerchApp/Workspace/Components/PerchSegmented.swift"


class SegmentedKeyboardOwnershipTests(unittest.TestCase):
    def test_first_tab_requires_the_native_segment_in_the_active_fixture(self):
        source = PROBE.read_text()
        run = source.split("func run() async throws {", 1)[1]
        run = run.split("private func testArrowsAndEnds()", 1)[0]
        ordered = ('try assertEditor(driver.before)',
                   r'try await key(code: 48, characters: "\t")',
                   'traceFocus("First Tab keyboard ownership")',
                   'let responder = window.firstResponder as? NSView',
                   'window.isKeyWindow && responder?.window === window',
                   'responder is PerchSegmentKeyView',
                   'try assertSelectedAndFocused(45)', 'try await testArrowsAndEnds()')
        for step in ordered:
            self.assertIn(step, run)
        positions = [run.index(step) for step in ordered]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn('SwiftUI.KeyViewProxy', run)
        assertion = source.split("private func assertSelectedAndFocused(", 1)[1]
        assertion = assertion.split("private func accessibilityNodes(", 1)[0]
        self.assertNotIn("SwiftUI.KeyViewProxy", assertion)
        self.assertIn("driver.minutes == minutes", assertion)
        self.assertLess(assertion.index("traceFocus("), assertion.index("try require("))

    def test_segment_retains_keyboard_focus_without_semantic_focus_override(self):
        source = COMPONENT.read_text()
        for removed in ("@AccessibilityFocusState", ".accessibilityFocused(", "@FocusState"):
            self.assertNotIn(removed, source)
        for retained in ("PerchSegmentKeyView: NSControl", "setAccessibilityRole(.button)",
                         "override var acceptsFirstResponder: Bool { active && enabled() && selected() }",
                         "window?.firstResponder === self", "window.makeFirstResponder(view)",
                         "override func isAccessibilitySelected() -> Bool { selected() }",
                         "override func isAccessibilityFocused() -> Bool", "window?.isKeyWindow == true"):
            self.assertIn(retained, source)

    def test_ax_focus_is_asserted_for_every_selected_and_departed_segment(self):
        source = PROBE.read_text()
        assertion = source.split("private func assertSelectedAndFocused(", 1)[1]
        assertion = assertion.split("private func accessibilityNodes(", 1)[0]
        self.assertIn('boolean(node, "isAccessibilityFocused") == (value == minutes)', assertion)
        cleared = source.split("private func assertNoSegmentFocus(", 1)[1]
        cleared = cleared.split("private func accessibilityNodes(", 1)[0]
        self.assertIn('boolean(node, "isAccessibilityFocused") == false', cleared)
        self.assertIn("controls.count == 4", cleared)
        self.assertIn("traceFocus(", cleared)
        for check in ("controls.count == 4", "for value in [15, 25, 45, 60]",
                      "matches.count == 1", 'attribute(node, "accessibilityValue") as? String',
                      '(value == minutes ? "Selected" : "Not selected")'):
            self.assertIn(check, assertion)


if __name__ == "__main__":
    unittest.main()
