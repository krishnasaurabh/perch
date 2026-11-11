"""Production workspace navigation contracts; native behavior lives in PerchAppTests."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class WorkspacePickerContractTests(unittest.TestCase):
    def test_production_picker_uses_shared_type_target_and_focus(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WorkspaceView.swift").read_text()
        self.assertNotIn(".system(size:", source)
        self.assertIn("Theme.minimumTarget", source)
        self.assertIn("PillStyle()", source)
        self.assertIn("ControlFocusRing(", source)
        self.assertIn(".focused($focusedPage, equals:", source)
        self.assertIn(".focusable(on)", source)
        for key in ("leftArrow", "rightArrow", "home", "end"):
            self.assertIn(f".onKeyPress(.{key})", source)
        self.assertIn('accessibilityIdentifier("workspace-more")', source)
        self.assertIn('accessibilityIdentifier("workspace-pages")', source)

    def test_page_crossfade_is_retained(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WorkspaceView.swift").read_text()
        self.assertIn("page.id(model.page).transition(.opacity)", source)
        self.assertIn("Motion.animate(Motion.page)", source)
        self.assertIn(".transaction { $0.animation = nil }", source)
        self.assertNotIn(".onAppear", source, "Passive presentation must not request focus")

    def test_native_regression_hosts_the_production_workspace(self):
        launcher = (ROOT / "Tests/PerchAppTests/WorkspaceNavigationTests.swift").read_text()
        self.assertIn("check_workspace_navigation.sh", launcher)
        self.assertIn("process.terminationStatus, 0", launcher)
        self.assertNotIn("Services(store:", launcher)
        source = (ROOT / "scripts/workspace_navigation_probe.swift").read_text()
        self.assertIn("WorkspaceView(notchHeight:", source)
        self.assertNotIn("SegmentPills(", source)
        for expected in ("testKeyboardGroup", "testPassive", "assertFocusRing", "isAccessibilityFocused"):
            self.assertIn(expected, source)


if __name__ == "__main__":
    unittest.main()
