"""Preference consumers must affect presentation, including retry feedback."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AgentSettingsConsumerTests(unittest.TestCase):
    def test_task_attribution_and_help_share_the_preference_guard(self):
        for path in ("Workspace/TaskRow.swift", "Settings/DashboardTaskLine.swift"):
            with self.subTest(path=path):
                source = (ROOT / "Sources/PerchApp" / path).read_text()
                self.assertIn(
                    "if store.prefs.showAgentAttribution, let agent = task.agentID, "
                    "let name = AgentName.short(agent) {", source)
                self.assertNotIn("if let agent = task.agentID", source)
                # The guarded branch owns the label and the tooltip together.
                branch = source.split("if store.prefs.showAgentAttribution", 1)[1].split("}", 1)[0]
                self.assertIn(".help(", branch)
                self.assertIn("name", branch)

    def test_retry_success_writes_back_to_the_view_binding(self):
        source = (ROOT / "Sources/PerchApp/Settings/AgentsSettings.swift").read_text()
        self.assertIn("message: $message", source)
        self.assertIn("message: Binding<String?>? = nil", source)
        operation = source.split("static func connectAgent(", 1)[1].split("static func disconnectAgent(", 1)[0]
        self.assertIn("message?.wrappedValue = result", operation)
        self.assertLess(operation.index("guard readStatus(app) == .connected"),
                        operation.index("message?.wrappedValue = result"))


if __name__ == "__main__":
    unittest.main()
