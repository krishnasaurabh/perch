"""Keep permission UI bound to queried state rather than request completion."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SettingsPermissionWiringTests(unittest.TestCase):
    def test_onboarding_uses_live_permission_panel(self):
        source = (ROOT / "Sources/PerchApp/Settings/WelcomeView.swift").read_text()
        self.assertNotIn("granted.insert", source)
        self.assertIn("PermissionPanel", source)

    def test_settings_exposes_overdue_policy(self):
        source = (ROOT / "Sources/PerchApp/Settings/SettingsView.swift").read_text()
        self.assertIn("pref(\\.carryMode)", source)
        self.assertIn("CarryMode.ask", source)
        self.assertIn("CarryMode.auto", source)
        self.assertIn("CarryMode.never", source)

    def test_clips_has_discoverable_actions_and_nonoverlay_undo(self):
        source = (ROOT / "Sources/PerchApp/Workspace/ClipsPage.swift").read_text()
        self.assertIn('Button("Copy"', source)
        self.assertIn('Button("Remove"', source)
        self.assertIn("ViewThatFits", source)
        self.assertNotIn(".overlay(alignment: .bottom)", source)


if __name__ == "__main__":
    unittest.main()
