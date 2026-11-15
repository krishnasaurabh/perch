"""Settings shell structure and pane ownership stay independent of native rendering."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SETTINGS = ROOT / "Sources/PerchApp/Settings"


class SettingsShellTests(unittest.TestCase):
    def test_five_panes_have_independent_entry_points(self):
        shell = (SETTINGS / "SettingsView.swift").read_text()
        for name in ("General", "Notch", "Calendar", "Agents", "Data"):
            pane = SETTINGS / f"Settings{name}Pane.swift"
            self.assertTrue(pane.exists(), pane.name)
            self.assertIn(f"struct Settings{name}Pane: View", pane.read_text())
            self.assertIn(f"Settings{name}Pane(", shell)
        self.assertNotIn("NavigationSplitView", shell)
        self.assertIn("DotGridSheet", shell)

    def test_shared_rows_use_tokens_and_keep_help_unclipped(self):
        shell = (SETTINGS / "SettingsView.swift").read_text()
        self.assertIn("struct SettingsSection", shell)
        self.assertIn("struct SettingsRow", shell)
        self.assertIn("DesignTokens.Size.buttonHeight.value", shell)
        self.assertIn("Theme.Size.cardEdge.value", shell)
        self.assertIn(".fixedSize(horizontal: false, vertical: true)", shell)
        self.assertNotIn("ViewThatFits", shell)
        self.assertNotIn(".clipped()", shell)

    def test_sidebar_selection_is_keyboard_accessible(self):
        shell = (SETTINGS / "SettingsView.swift").read_text()
        self.assertIn(".focused($focusedPane, equals: pane)", shell)
        self.assertIn(".onMoveCommand", shell)
        self.assertIn("FocusRing(", shell)
        self.assertIn(".isSelected", shell)
        self.assertIn('"settings.sidebar.', shell)

    def test_each_pane_is_registered_and_captured(self):
        registry = (ROOT / "Sources/PerchApp/App/AppDelegate+Preview.swift").read_text()
        shots = (ROOT / "scripts/redesign_shots.list").read_text()
        for pane in ("general", "notch", "calendar", "agents", "data"):
            self.assertIn(f'"settings/{pane}": .window("settings")', registry)
            self.assertRegex(shots, rf"(?m)^settings-{pane} .*--open settings/{pane}$")

    def test_failure_ownership_survives_navigation(self):
        shell = (SETTINGS / "SettingsView.swift").read_text()
        self.assertIn("@StateObject private var feedback = SettingsFailureFeedback()", shell)
        self.assertIn("SettingsDetail(feedback: feedback)", shell)
        self.assertIn('Button("Retry"', shell)
        self.assertIn("feedback.canRetry(error)", shell)
        self.assertIn("store.$lastError.sink", shell)

    def test_retired_capture_and_fake_notch_controls_are_not_offered(self):
        sources = "\n".join(p.read_text() for p in SETTINGS.glob("Settings*Pane.swift"))
        self.assertNotIn("catchScreenshots", sources)
        self.assertNotIn("catchCopies", sources)
        self.assertNotIn("notchOnMonitors", sources)


if __name__ == "__main__":
    unittest.main()
