"""Native segment ownership cannot restore focus after leaving the group."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
COMPONENT = ROOT / "Sources/PerchApp/Workspace/Components/PerchSegmented.swift"


class SegmentedFocusLifecycleTests(unittest.TestCase):
    def test_key_selection_uses_registered_native_views_synchronously(self):
        source = COMPONENT.read_text()
        for token in ("views[value] = WeakSegmentView(view)", "selection = value", "change(value)",
                      "if acquireFocus { focus(value) }", "window.makeFirstResponder(view)",
                      "else if changed && ownsFocus", "let window = view.window, window.isKeyWindow"):
            self.assertIn(token, source)
        self.assertNotIn("DispatchQueue.main.async", source)
        self.assertNotIn("@FocusState", source)

    def test_group_exit_invalidates_ownership_without_queued_work(self):
        source = COMPONENT.read_text()
        for token in ("NSWindow.didResignKeyNotification", "focus.resign(in: window)",
                      ".onDisappear { focus.resign() }", "if !enabled", "resign()",
                      "view.window === window", "view.window?.makeFirstResponder(nil)",
                      "dismantleNSView", "view.active = false", "view.focusChanged(false)"):
            self.assertIn(token, source)
        self.assertNotIn("restorationID", source)

    def test_native_regression_drives_keys_and_observes_focus(self):
        source = (ROOT / "Tests/PerchAppTests/SegmentedKeyboardTests.swift").read_text()
        for evidence in ("PerchSegmented(", "window.sendEvent", "isAccessibilityFocused",
                         'characters: "\\u{19}"', "testArrowsAndEnds", "testExitAndCancellation",
                         "testDisabledAndInactive", "testExternalSelection", "try await check.run()"):
            self.assertIn(evidence, source)
        self.assertNotIn("accessibilityPerformPress", source)


if __name__ == "__main__":
    unittest.main()
