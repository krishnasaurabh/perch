"""Calendar settings use typed actions, shared permission recovery and foundation controls."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CalendarSettingsWiringTests(unittest.TestCase):
    def test_each_control_uses_the_typed_preference_action(self):
        source = (ROOT / 'Sources/PerchApp/Settings/SettingsCalendarPane.swift').read_text()
        for name in ('showCalendarMeetings', 'hiddenCalendarIDs', 'meetingHeadsUp',
                     'notifyWhenClosed', 'persistentReminders', 'snoozeMinutes',
                     'remindersSync', 'phoneEdits'):
            self.assertIn(f'save(.{name}(', source)
        self.assertIn('try $0.updatePreference(update)', source)
        self.assertNotIn('store.updatePrefs', source)

    def test_uses_foundation_controls_and_permission_panel(self):
        source = (ROOT / 'Sources/PerchApp/Settings/SettingsCalendarPane.swift').read_text()
        for component in ('PerchSwitch(', 'PerchSegmented(', 'PerchButton(', 'PerchPill(',
                          'SettingsSection(', 'SettingsRow(', 'PermissionPanel(model:'):
            self.assertIn(component, source)
        self.assertNotIn('ViewThatFits', source)
        self.assertNotIn('.font(.system', source)
        for feature in ('calendar', 'notifications', 'reminders'):
            self.assertIn(f'allow(.{feature})', source)
        self.assertIn('setTwoWayEnabled(enabled)', source)
        self.assertIn('confirmingPhoneEdits = true', source)
        self.assertIn('NSApplication.didBecomeActiveNotification', source)
        self.assertIn('publisher(for: .EKEventStoreChanged)', source)
        self.assertIn('if let error = sync.lastError {', source)
        self.assertNotIn('if let error = sync.lastError, store.prefs.remindersSync', source)

    def test_permission_recovery_requeries_and_uses_system_settings(self):
        source = (ROOT / 'Sources/PerchApp/Settings/PermissionPanel.swift').read_text()
        self.assertIn('func ensureAllowed', source)
        self.assertIn('await refresh()', source)
        self.assertIn('readings[feature]?.state == .allowed', source)
        self.assertIn('NSWorkspace.shared.open(feature.settingsURL)', source)
        self.assertIn('PerchButton("System Settings…"', source)
        self.assertNotIn('ViewThatFits', source)

    def test_all_preview_states_are_registered_and_captured(self):
        registry = (ROOT / 'Sources/PerchApp/App/AppDelegate+Preview.swift').read_text()
        shots = (ROOT / 'scripts/redesign_shots.list').read_text()
        for suffix in ('', '-denied', '-picker'):
            target = 'settings/calendar' + suffix
            self.assertIn(f'"{target}": .window(', registry)
            self.assertIn(f'--open {target}', shots)
        self.assertIn('"settings/calendar": .window("settings") { SettingsCalendarPreview.show(.standard', registry)
        self.assertIn('#if DEBUG || PERCH_TESTING',
                      (ROOT / 'Sources/PerchApp/Settings/SettingsCalendarPane.swift').read_text())


if __name__ == '__main__':
    unittest.main()
