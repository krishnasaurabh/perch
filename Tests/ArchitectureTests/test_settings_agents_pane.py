"""The agent pane uses the shared controls and the persisted typed actions."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SettingsAgentsPaneTests(unittest.TestCase):
    def test_sections_and_controls_match_the_agent_preferences(self):
        source = (ROOT / "Sources/PerchApp/Settings/SettingsAgentsPane.swift").read_text()
        for title in ("What agents may do", "Their changes"):
            self.assertIn(f'SettingsSection("{title}")', source)
        for key in ("agentsCanEditTasks", "agentsCanControlTime", "agentsCanReadParkingLot",
                    "showAgentAttribution", "confirmAgentDeletes"):
            self.assertIn(f"\\.{key}", source)
            self.assertIn(f".{key}(value)", source)
        self.assertIn("SettingsRow(", source)
        self.assertIn("PerchSwitch(", source)
        self.assertIn("try $0.updatePreference(", source)
        self.assertIn("Anything an agent does shows up in the notch and can be undone with ⌘Z.", source)
        self.assertNotIn("ViewThatFits", source)

    def test_connection_rows_use_shared_components_and_refresh(self):
        source = (ROOT / "Sources/PerchApp/Settings/AgentsSettings.swift").read_text()
        for text in ('SettingsSection("Connected apps")', 'SettingsRow(', 'PerchButton(',
                     '"Claude Desktop"', '"Connected"', '"Not connected"', '"Not installed"'):
            self.assertIn(text, source)
        self.assertIn("feedback.perform(", source)
        self.assertIn(".onAppear(perform: refresh)", source)
        self.assertIn("failedAgentDisconnects", source)
        self.assertIn("if !AppInfo.isInApplications && !Self.isPreview", source)
        self.assertIn('"Agent setup requires Perch to be installed in Applications."', source)

    def test_preview_variants_are_registered_without_host_configuration(self):
        source = (ROOT / "Sources/PerchApp/Settings/AgentsSettings.swift").read_text()
        self.assertIn("AppDelegate.snapshotDate != nil", source)
        self.assertEqual(source.count("guard !Self.isPreview else { return }"), 2)
        registry = (ROOT / "Sources/PerchApp/App/AppDelegate+Preview.swift").read_text()
        self.assertIn('"settings/agents-connected": .window("settings")', registry)
        shots = (ROOT / "scripts/redesign_shots.list").read_text()
        self.assertIn("settings-agents-connected --scenario empty --open settings/agents-connected", shots)


if __name__ == "__main__":
    unittest.main()
