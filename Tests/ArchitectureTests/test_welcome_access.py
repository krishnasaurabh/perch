"""Source-level guards for first-run access; native behavior is covered on macOS."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "Sources/PerchApp"


def body(path, signature):
    source = (APP / path).read_text()
    start = source.index("{", source.index(signature))
    depth = 1
    end = start + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


class WelcomeAccessTests(unittest.TestCase):
    def assert_no_request(self, content):
        self.assertNotIn("requestAccess(", content)
        self.assertNotIn("requestAuthorization(", content)
        self.assertNotIn("requestFullAccess", content)

    def test_welcome_is_not_a_permission_or_capture_surface(self):
        content = (APP / "Settings/WelcomeView.swift").read_text()
        self.assert_no_request(content)
        for old in ("PermissionPanel(", "WelcomeScreenshotConsent", "catchScreenshots", "catchCopies"):
            self.assertNotIn(old, content)
        self.assertIn('keyboardShortcut(.defaultAction)', content)
        self.assertIn('keyboardShortcut(.cancelAction)', content)
        self.assertIn('PerchSwitch(title: title, isOn: value)', content)

    def test_service_construction_does_not_request_permissions(self):
        for path in ("Services", "CalendarService", "ReminderService", "RemindersSync", "VoiceCapture"):
            self.assert_no_request(body(f"Services/{path}.swift", "init("))

    def test_calendar_refresh_does_not_request_access(self):
        self.assert_no_request(body("Services/CalendarService.swift", "func refresh("))
        self.assertIn("source.requestAccess()", body("Services/CalendarService.swift", "func requestAccess("))

    def test_notification_launch_reconciliation_only_checks_authorization(self):
        self.assert_no_request(body("Services/ReminderService.swift", "private func start("))
        reconcile = body("Services/ReminderService.swift", "private func reconcilePass(")
        self.assert_no_request(reconcile)
        self.assertIn("source.isAuthorized()", reconcile)
        self.assertIn("source.requestAuthorization()", body("Services/ReminderService.swift", "func requestAuthorization("))

    def test_voice_requests_only_from_explicit_start(self):
        start = body("Services/VoiceCapture.swift", "func start(")
        self.assertIn("SFSpeechRecognizer.requestAuthorization", start)
        self.assertIn("AVCaptureDevice.requestAccess(for: .audio)", start)
        self.assertIn("await start(onFinish:", body("Services/VoiceCapture.swift", "func toggle("))

    def test_click_gate_uses_independent_preference_and_keeps_legacy_double_click(self):
        source = (APP / "Notch/NotchController.swift").read_text()
        self.assertIn("if prefs.notchClickToOpen || (prefs.notchOpenTrigger == .doubleClick && e.clickCount >= 2)", source)
        self.assertNotIn("if prefs.notchOpenTrigger == .click ||", source)

    def test_welcome_has_a_registered_snapshot(self):
        registry = (APP / "App/AppDelegate+Preview.swift").read_text()
        self.assertIn('"welcome": .window("welcome")', registry)
        shots = (ROOT / "scripts/redesign_shots.list").read_text().splitlines()
        self.assertIn("welcome --scenario empty --open welcome", shots)


if __name__ == "__main__":
    unittest.main()
