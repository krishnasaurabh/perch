"""Keep native focus diagnostics on the same unfiltered inventory as assertions."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SEGMENTED = ROOT / "Tests/PerchAppTests/SegmentedKeyboardTests.swift"
WEEK = ROOT / "Tests/PerchAppTests/WeekInboxKeyboardTests.swift"


def body(source, signature):
    """Extract one brace-balanced Swift function body."""
    start = source.index("{", source.index(signature))
    depth = 1
    for end in range(start + 1, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if not depth:
            return source[start + 1:end]
    raise AssertionError(f"Unclosed function: {signature}")


def normalized(source):
    return re.sub(r"\s+", "", re.sub(r"//[^\n]*", "", source))


class ControlFocusInventoryTests(unittest.TestCase):
    def test_full_walker_matches_the_native_week_reference(self):
        source = SEGMENTED.read_text()
        actual = body(source, "private func accessibilityNodes(_ root: NSObject)")
        reference = body(WEEK.read_text(), "private static func nodes(_ root: NSObject)")
        self.assertEqual(normalized(actual.replace("attribute(", "value(")), normalized(reference))
        # The inventory must keep fields and containers, not only the segment buttons.
        self.assertIn("return retained", actual)
        self.assertNotIn('"AXButton"', actual)

    def test_trace_dumps_every_visited_node_and_returns_that_snapshot(self):
        source = SEGMENTED.read_text()
        trace = body(source, "private func traceFocus(")
        self.assertIn("-> [NSObject]", source.split("private func traceFocus(", 1)[1].split("{", 1)[0])
        self.assertEqual(trace.count("accessibilityNodes(window)"), 1)
        self.assertIn("let nodes = accessibilityNodes(window)", trace)
        self.assertIn("for (index, node) in nodes.enumerated()", trace)
        for field in ("accessibilityRole", "label(node)", "accessibilityIdentifier", "isAccessibilityFocused"):
            self.assertIn(field, trace)
        for field in ("role=", "label=", "identifier=", "isAccessibilityFocused="):
            self.assertIn(field, trace)
        self.assertIn("return nodes", trace)
        self.assertNotIn("segmentNodes(", trace)

    def test_assertions_inspect_the_exact_snapshot_logged_before_them(self):
        source = SEGMENTED.read_text()
        for name in ("assertEditor", "assertSelectedAndFocused", "assertNoSegmentFocus"):
            with self.subTest(assertion=name):
                assertion = body(source, f"private func {name}(")
                self.assertEqual(assertion.count("traceFocus("), 1)
                self.assertLess(assertion.index("traceFocus("), assertion.index("try require("))
                self.assertNotIn("accessibilityNodes(", assertion)
                if name != "assertEditor":
                    self.assertIn("let nodes = traceFocus(", assertion)
                    self.assertIn("segmentNodes(in: nodes)", assertion)
                self.assertNotIn("segmentNodes()", assertion)

    def test_segment_filter_keeps_exact_roles_and_labels(self):
        selector = body(SEGMENTED.read_text(), "private func segmentNodes(in nodes: [NSObject])")
        self.assertIn("nodes.filter", selector)
        self.assertIn('attribute($0, "accessibilityRole") as? String == "AXButton"', selector)
        self.assertIn('["15", "25", "45", "60"].contains(label($0) ?? "")', selector)
        self.assertNotIn("accessibilityNodes(", selector)


if __name__ == "__main__":
    unittest.main()
