"""Keep native keyboard ownership separate from semantic AX focus publication."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
PROBE = ROOT / "Tests/PerchAppTests/SegmentedKeyboardTests.swift"
COMPONENT = ROOT / "Sources/PerchApp/Workspace/Components/PerchSegmented.swift"


class SegmentedKeyboardOwnershipTests(unittest.TestCase):
    def test_only_first_tab_requires_a_key_view_in_the_active_fixture(self):
        source = PROBE.read_text()
        run = source.split("func run() async throws {", 1)[1]
        run = run.split("private func testArrowsAndEnds()", 1)[0]
        ordered = ('try assertEditor(driver.before)',
                   r'try await key(code: 48, characters: "\t")',
                   'traceFocus("First Tab keyboard ownership")',
                   'let responder = window.firstResponder as? NSView',
                   'window.isKeyWindow && responder?.window === window',
                   'String(reflecting: type(of: $0)) == "SwiftUI.KeyViewProxy"',
                   'try assertSelectedAndFocused(45)', 'try await testArrowsAndEnds()')
        for step in ordered:
            self.assertIn(step, run)
        positions = [run.index(step) for step in ordered]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(run.count('"SwiftUI.KeyViewProxy"'), 1)
        assertion = source.split("private func assertSelectedAndFocused(", 1)[1]
        assertion = assertion.split("private func accessibilityNodes(", 1)[0]
        self.assertNotIn("SwiftUI.KeyViewProxy", assertion)
        self.assertIn("driver.minutes == minutes", assertion)
        self.assertLess(assertion.index("traceFocus("), assertion.index("try require("))

    def test_segment_retains_keyboard_focus_without_semantic_focus_override(self):
        source = COMPONENT.read_text()
        for removed in ("@AccessibilityFocusState", ".accessibilityFocused(", "accessibilityFocus"):
            self.assertNotIn(removed, source)
        for retained in ("@FocusState private var focused: Value?",
                         ".focusable(enabled && selected)",
                         ".focused($focused, equals: item.value)",
                         ".accessibilityAddTraits(selected ? .isSelected : [])",
                         ".onChange(of: focused) { oldValue, value in",
                         "groupHasFocus = true", "focused = value"):
            self.assertIn(retained, source)

    def test_ax_focus_is_diagnostic_only_while_publication_is_deferred(self):
        source = PROBE.read_text()
        assertion = source.split("private func assertSelectedAndFocused(", 1)[1]
        assertion = assertion.split("private func accessibilityNodes(", 1)[0]
        self.assertNotIn("isAccessibilityFocused", assertion)
        self.assertNotIn("assertNoSegmentFocus", source)
        diagnostics = source.split("private func traceFocus(", 1)[1].split("private func assertEditor(", 1)[0]
        self.assertEqual(source.count("isAccessibilityFocused"), diagnostics.count("isAccessibilityFocused"))
        self.assertIn('boolean(node, "isAccessibilityFocused")', diagnostics)
        for check in ("controls.count == 4", "for value in [15, 25, 45, 60]",
                      "matches.count == 1", 'attribute(node, "accessibilityValue") as? String',
                      '(value == minutes ? "Selected" : "Not selected")'):
            self.assertIn(check, assertion)


if __name__ == "__main__":
    unittest.main()
