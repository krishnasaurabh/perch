"""Roving focus survives replacement without reclaiming a departed group."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
COMPONENT = ROOT / "Sources/PerchApp/Workspace/Components/PerchSegmented.swift"


class SegmentedFocusLifecycleTests(unittest.TestCase):
    def test_key_selection_waits_for_registration(self):
        source = COMPONENT.read_text()
        handler = source.split("private func select(_ index:", 1)[1].split("\n    }", 1)[0]
        self.assertNotIn("focused =", handler)
        self.assertIn("selection = items[index].value", handler)
        self.assertIn(".onChange(of: selection)", source)
        self.assertIn(".onChange(of: focused)", source)
        self.assertIn("@State private var groupHasFocus = false", source)
        restore = source.split("private func restoreFocus(", 1)[1].split("private func", 1)[0]
        for guard in ("DispatchQueue.main.async", "groupHasFocus", "enabled", "selection == value",
                      "isKeyWindow == true", "restorationID == request", "focused = value"):
            self.assertIn(guard, restore)

    def test_group_exit_invalidates_queued_work(self):
        source = COMPONENT.read_text()
        for hook in (".onKeyPress(.tab)", ".onChange(of: enabled)", ".onDisappear",
                     "NSWindow.didResignKeyNotification", "window === focusAnchor.window"):
            self.assertIn(hook, source)
        leave = source.split("private func leaveGroup(", 1)[1].split("\n    }", 1)[0]
        self.assertIn("groupHasFocus = false", leave)
        self.assertIn("restorationID = UUID()", leave)
        self.assertIn("return .ignored", leave, "Tab must reach the next native destination")
        self.assertIn("oldValue == selection", source,
                      "Only a real exit, not the outgoing selection's temporary nil, ends ownership")

    def test_native_regression_drives_keys_and_observes_focus(self):
        source = (ROOT / "Tests/PerchAppTests/SegmentedKeyboardTests.swift").read_text()
        for evidence in ("PerchSegmented(", "window.sendEvent", "isAccessibilityFocused",
                         'characters: "\\u{19}"', "testArrowsAndEnds", "testExitAndCancellation",
                         "testDisabledAndInactive", "testExternalSelection", "try await check.run()"):
            self.assertIn(evidence, source)
        self.assertNotIn("accessibilityPerformPress", source,
                         "An AX press bypasses the keyboard registration regression")


if __name__ == "__main__":
    unittest.main()
