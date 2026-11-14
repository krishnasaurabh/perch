"""Keep a segment's semantic focus tied to keyboard ownership, not selection."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
COMPONENT = ROOT / "Sources/PerchApp/Workspace/Components/PerchSegmented.swift"


class SegmentedAccessibilityFocusTests(unittest.TestCase):
    def test_keyboard_and_accessibility_focus_bind_the_same_segment(self):
        source = COMPONENT.read_text()
        self.assertIn("@FocusState private var focused: Value?", source)
        self.assertIn("@AccessibilityFocusState private var accessibilityFocus: Value?", source)
        segment = source.split("ForEach(items.indices", 1)[1].split(".onKeyPress(.leftArrow)", 1)[0]
        for modifier in (
            ".focusable(enabled && selected)",
            ".focused($focused, equals: item.value)",
            ".accessibilityAddTraits(selected ? .isSelected : [])",
            ".accessibilityFocused($accessibilityFocus, equals: item.value)",
        ):
            self.assertIn(modifier, segment)
        self.assertEqual(source.count(".accessibilityFocused("), 1)
        self.assertNotIn("makeFirstResponder", source)
        self.assertNotIn("setAccessibilityFocused", source)

    def test_semantic_focus_tracks_keyboard_changes_including_nil(self):
        source = COMPONENT.read_text()
        observation = source.split(".onChange(of: focused) { oldValue, value in", 1)[1]
        observation = observation.split(".onChange(of: selection)", 1)[0]
        self.assertIn("accessibilityFocus = enabled ? value : nil", observation)
        self.assertLess(observation.index("accessibilityFocus ="), observation.index("if value != nil"))
        self.assertNotIn("accessibilityFocus = selection", source,
                         "A selected but unfocused group must not capture accessibility focus")

    def test_departure_clears_semantic_focus_without_intercepting_tab(self):
        source = COMPONENT.read_text()
        departure = source.split("private func leaveGroup()", 1)[1].split("private func move(", 1)[0]
        for operation in ("groupHasFocus = false", "restorationID = UUID()",
                          "accessibilityFocus = nil", "return .ignored"):
            self.assertIn(operation, departure)
        self.assertNotIn("focused = nil", departure,
                         "Native Tab traversal must retain its outgoing keyboard destination")
        for hook in (".onKeyPress(.tab) { leaveGroup() }",
                     r'.onKeyPress(KeyEquivalent("\u{19}")) { leaveGroup() }',
                     ".onChange(of: enabled)", "NSWindow.didResignKeyNotification", ".onDisappear"):
            self.assertIn(hook, source)

    def test_external_selection_only_queues_guarded_keyboard_restoration(self):
        source = COMPONENT.read_text()
        self.assertIn(".onChange(of: selection) { _, value in restoreFocus(value) }", source)
        restore = source.split("private func restoreFocus(", 1)[1].split("private func leaveGroup", 1)[0]
        for condition in ("groupHasFocus", "enabled", "selection == value", "restorationID == request",
                          "isKeyWindow == true", "items.contains", "focused = value"):
            self.assertIn(condition, restore)
        self.assertNotIn("accessibilityFocus =", restore,
                         "Publish semantic focus after actual keyboard focus changes, not a binding edit")


if __name__ == "__main__":
    unittest.main()
