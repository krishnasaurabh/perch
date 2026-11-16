"""Connection guidance and retries must have the same window lifetime."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AgentGuidanceLifetimeTests(unittest.TestCase):
    def test_guidance_is_published_by_the_window_owned_feedback(self):
        shell = (ROOT / "Sources/PerchApp/Settings/SettingsView.swift").read_text()
        self.assertIn("@StateObject private var feedback = SettingsFailureFeedback()", shell)
        feedback = shell.split("final class SettingsFailureFeedback:", 1)[1]
        self.assertIn("@Published var agentConnectionMessage: String?", feedback)

    def test_agents_pane_uses_a_binding_to_that_owner_not_local_state(self):
        source = (ROOT / "Sources/PerchApp/Settings/AgentsSettings.swift").read_text()
        self.assertNotIn("@State private var message", source)
        self.assertIn("@Binding private var message: String?", source)
        self.assertIn("feedback?.agentConnectionMessage", source)
        self.assertIn("message: $message", source)
        self.assertIn("message?.wrappedValue = result", source)
        # Retained retry operations must not keep their feedback owner alive through the binding.
        self.assertIn("get: { [weak feedback] in feedback?.agentConnectionMessage }", source)
        self.assertIn("set: { [weak feedback] in feedback?.agentConnectionMessage = $0 }", source)


if __name__ == "__main__":
    unittest.main()
