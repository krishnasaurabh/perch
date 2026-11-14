"""Keep native keyboard ownership separate from semantic AX focus publication."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
PROBE = ROOT / "Tests/PerchAppTests/SegmentedKeyboardTests.swift"


class SegmentedKeyboardOwnershipTests(unittest.TestCase):
    def test_each_selected_step_checks_a_key_view_in_the_active_fixture(self):
        source = PROBE.read_text()
        assertion = source.split("private func assertSelectedAndFocused(", 1)[1]
        assertion = assertion.split("private func assertNoSegmentFocus(", 1)[0]
        for check in ("window.isKeyWindow", "responder?.window === window",
                      'String(reflecting: type(of: $0)) == "SwiftUI.KeyViewProxy"',
                      "driver.minutes == minutes"):
            self.assertIn(check, assertion)
        self.assertLess(assertion.index("traceFocus("), assertion.index("window.isKeyWindow"))

    def test_only_positive_ax_focus_is_deferred(self):
        source = PROBE.read_text()
        assertion = source.split("private func assertSelectedAndFocused(", 1)[1]
        assertion = assertion.split("private func assertNoSegmentFocus(", 1)[0]
        self.assertNotIn('boolean(node, "isAccessibilityFocused") == (value == minutes)', assertion)
        self.assertIn("if value != minutes {", assertion)
        self.assertIn('boolean(node, "isAccessibilityFocused") == false', assertion)
        for check in ("controls.count == 4", "for value in [15, 25, 45, 60]",
                      "matches.count == 1", 'attribute(node, "accessibilityValue") as? String',
                      '(value == minutes ? "Selected" : "Not selected")'):
            self.assertIn(check, assertion)
        self.assertIn('boolean($0, "isAccessibilityFocused") != true', source)


if __name__ == "__main__":
    unittest.main()
