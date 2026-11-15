"""Notch settings use the shared controls and typed persistent preference actions."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
PANE = ROOT / "Sources/PerchApp/Settings/SettingsNotchPane.swift"


class SettingsNotchPaneTests(unittest.TestCase):
    def test_all_eight_controls_have_shared_components_and_bindings(self):
        source = PANE.read_text()
        for label, control in (
            ("Progress line under the housing", "progressLine"),
            ("Time pill beside the notch", "timePill"),
            ("Tasks-left pill beside the notch", "taskPill"),
            ("Pills sit on the", "pillSide"),
            ("Show the next block in its last 15 minutes", "nextBlock"),
            ("Dot under the housing for a waiting reminder", "reminderDot"),
            ("Show Perch in the menu bar as", "menuBar"),
            ("Hide counts and times", "privacy"),
        ):
            with self.subTest(control=control):
                self.assertIn(f'SettingsRow("{label}"', source)
                self.assertIn(f"preferences.{control}", source)
        self.assertEqual(source.count("PerchSwitch("), 6)
        self.assertEqual(source.count("PerchSegmented("), 2)
        for title in ("Around the notch", "Pill details", "Menu bar"):
            self.assertIn(f'SettingsSection("{title}")', source)
        self.assertNotIn("Picker(", source)
        self.assertNotIn("ViewThatFits", source)

    def test_bindings_use_typed_actions_not_local_drafts(self):
        source = PANE.read_text()
        for name in (
            "notchProgressLine", "notchTimePill", "notchTaskCount", "notchTimerPlacement",
            "notchNextBlock", "notchReminderDot", "menuBarDisplay", "hideCountsAndTimes",
        ):
            with self.subTest(preference=name):
                self.assertRegex(source, rf"binding\(\\\.{name}, update: PreferenceUpdate\.{name}\)")
        self.assertIn("store.apply { try $0.updatePreference(update(value)) }", source)
        self.assertIn("store.prefs[keyPath: keyPath]", source)
        self.assertNotIn("@State", source)
        self.assertNotRegex(source, r"Color\(|\.font\(\.system|\.frame\([^)]*\b\d+")

    def test_privacy_is_truthfully_manual_and_menu_placement_is_explained(self):
        source = PANE.read_text()
        self.assertIn("Screen sharing is not detected automatically.", source)
        self.assertNotIn("while sharing my screen", source)
        self.assertIn("macOS places the menu bar item itself", source)

    def test_notch_snapshot_target_covers_both_appearances(self):
        shots = (ROOT / "scripts/redesign_shots.list").read_text()
        self.assertRegex(shots, r"(?m)^settings-notch .*--open settings/notch$")
        script = (ROOT / "scripts/redesign_shots.sh").read_text()
        self.assertIn('for appearance in ("light", "dark"):', script)
        registry = (ROOT / "Sources/PerchApp/App/AppDelegate+Preview.swift").read_text()
        self.assertIn('"settings/notch": .window("settings")', registry)
        self.assertIn('"settings/notch-configured": .window("settings"', registry)
        self.assertIn('settings-notch-configured --scenario empty --open settings/notch-configured', shots)


if __name__ == "__main__":
    unittest.main()
