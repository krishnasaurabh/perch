"""Keep independent app features out of shared composition and token files."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "Sources/PerchApp"


class AppUnitTests(unittest.TestCase):
    def test_services_only_composes_integrations(self):
        source = (APP / "Services/Services.swift").read_text()
        self.assertEqual(re.findall(r"^final class (\w+)", source, re.M), ["Services"])
        self.assertNotRegex(source, r"import (AVFoundation|EventKit|Speech|UserNotifications)")

    def test_week_and_clips_have_separate_entry_points(self):
        self.assertFalse((APP / "Workspace/WeekAndClips.swift").exists())
        week = (APP / "Workspace/WeekPage.swift").read_text()
        clips = (APP / "Workspace/ClipsPage.swift").read_text()
        self.assertIn("struct WeekPage: View", week)
        self.assertIn("struct ClipsPage: View", clips)
        self.assertNotIn("ClipsService", week)
        self.assertNotIn("WeekColumnLayout", clips)

    def test_settings_and_dashboard_are_independent(self):
        self.assertFalse((APP / "Settings/SettingsAndDashboard.swift").exists())
        settings = (APP / "Settings/SettingsView.swift").read_text()
        dashboard = (APP / "Settings/DashboardView.swift").read_text()
        self.assertIn("struct SettingsView: View", settings)
        self.assertIn("struct DashboardView: View", dashboard)
        self.assertNotIn("struct Dashboard", settings)
        self.assertNotIn("struct Settings", dashboard)

    def test_theme_contains_tokens_not_components_or_motion(self):
        source = (APP / "Workspace/Theme.swift").read_text()
        self.assertIn("enum Theme {", source)
        self.assertNotRegex(source, r"(?m)^(?:private )?(struct|extension|enum Motion)\b")
        self.assertNotIn("Animation.", source)

    def test_app_delegate_does_not_define_views_or_speech(self):
        source = (APP / "App/AppDelegate.swift").read_text()
        self.assertNotIn("struct WelcomeView", source)
        self.assertNotIn("SFSpeechRecognizer", source)
        self.assertNotIn("extension PlannerStore", source)

    def test_presentation_activity_is_not_a_timeline_type(self):
        sources = "\n".join(p.read_text() for p in APP.rglob("*.swift"))
        self.assertNotRegex(sources, r"\b(?:struct|class|enum|typealias) NotchActivity\b")
        self.assertIn("struct PresentedNotchActivity: Identifiable, Equatable", sources)
        self.assertIn("private typealias Activity = PerchUI.NotchActivity", sources)


if __name__ == "__main__":
    unittest.main()
