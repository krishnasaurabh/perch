"""Data settings keep action routing explicit and use the shared foundation."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
PANE = ROOT / "Sources/PerchApp/Settings/SettingsDataPane.swift"


class SettingsDataContractTests(unittest.TestCase):
    def test_all_rows_and_foundation_controls_are_present(self):
        source = PANE.read_text()
        for label in (
            "Where it lives", "On this Mac only", "Backups", "Last backup",
            "Take it with you", "Export everything", "Bring tasks in from a file",
            "Tidy up", "Clear finished tasks older than", "Empty the parking lot",
            "Erase everything on this Mac",
        ):
            self.assertIn(f'"{label}"', source)
        self.assertIn("SettingsSection(", source)
        self.assertIn("SettingsRow(", source)
        self.assertIn("PerchButton(", source)
        self.assertIn("PerchSegmented(", source)
        self.assertNotIn("ViewThatFits", source)
        self.assertNotRegex(source, r"\.(?:font|cornerRadius)\(\s*[0-9]")

    def test_retention_routes_through_typed_preference_action(self):
        source = PANE.read_text()
        self.assertIn(".finishedTaskRetention(value)", source)
        self.assertIn("updatePreference(", source)
        self.assertIn("get: { store.prefs.finishedTaskRetention }", source)

    def test_destructive_entry_points_all_confirm_before_mutating(self):
        source = PANE.read_text()
        for method, request in (
            ("emptyParkingLot", ".emptyParkingLot"),
            ("eraseEverything", ".eraseEverything"),
            ("restoreBackup", ".restoreBackup"),
        ):
            body = source.split(f"func {method}(", 1)[1].split("\n    }", 1)[0]
            self.assertIn(f"guard confirm({request}) else {{ return }}", body)
        self.assertIn("guard value == .never || confirm(.retention(value))", source)
        self.assertIn('alert.addButton(withTitle: AppL10n.text("Cancel"))', source)
        self.assertIn("== .alertSecondButtonReturn", source)

    def test_cancel_escape_does_not_compete_with_a_return_default(self):
        source = PANE.read_text()
        body = source.split("static func alert(for", 1)[1].split("return alert", 1)[0]
        self.assertIn(r'cancel.keyEquivalent = "\u{1b}"', body)
        self.assertIn('proceed.keyEquivalent = ""', body)
        self.assertNotIn("defaultButtonCell =", body,
                         "AppKit couples the default cell to Return, not Escape")

    def test_live_storage_is_used_instead_of_a_fictional_backup_schedule(self):
        source = PANE.read_text()
        self.assertIn("PlannerFile.backupLimit", source)
        self.assertIn("file.backupURLs()", source)
        self.assertIn(".contentModificationDateKey", source)
        self.assertNotIn("Hourly and daily", source)
        self.assertNotIn("kept 30 days", source)
        self.assertIn("store.file.url", source)

    def test_last_backup_uses_fixed_width_digits(self):
        source = PANE.read_text()
        label = source.split("Text(backups.label)", 1)[1].split("SettingsSection", 1)[0]
        self.assertIn(".monospacedDigit()", label)

    def test_actions_and_snapshot_registration_are_retained(self):
        source = PANE.read_text()
        self.assertIn("feedback.exportBackup(to: url, store: store)", source)
        self.assertIn("store.restoreLatestBackup()", source)
        self.assertIn(".eraseLocalPlanner", source)
        self.assertIn("importTasks(from:", source)
        shots = (ROOT / "scripts/redesign_shots.list").read_text()
        self.assertRegex(shots, r"(?m)^settings-data .*--open settings/data$")
        runner = (ROOT / "scripts/redesign_shots.sh").read_text()
        self.assertIn("dark", runner)
        self.assertIn("light", runner)


if __name__ == "__main__":
    unittest.main()
