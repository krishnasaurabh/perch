"""General Settings keeps its controls on the typed command path."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class GeneralSettingsContract(unittest.TestCase):
    def test_nine_controls_are_in_spec_order(self):
        source = (ROOT / 'Sources/PerchApp/Settings/SettingsGeneralPane.swift').read_text()
        labels = [
            'Hovering over the notch shows', 'ShortcutPreferenceRow(store: store)',
            'Open Perch when you log in', 'A new day starts at',
            'Tasks left from yesterday', 'Time to set aside by default',
            'Heads-up before it ends', 'When a block ends', 'Play a chime when it ends',
        ]
        positions = [source.index(label) for label in labels]
        self.assertEqual(positions, sorted(positions))
        for action in ('resetHour', 'carryMode', 'defaultFocusMinutes',
                       'blockHeadsUp', 'blockEndAction', 'focusCompletionSound'):
            self.assertIn(f'update: PreferenceUpdate.{action}', source)
        self.assertIn('try $0.updatePreference(update(value))', source)
        self.assertNotIn('ViewThatFits', source)

    def test_shortcut_uses_typed_storage_and_shared_foundation(self):
        source = (ROOT / 'Sources/PerchApp/Settings/ShortcutPreferenceRow.swift').read_text()
        for required in ('SettingsRow("Shortcut to open and start typing")', 'PerchButton(',
                         '.openShortcut(', 'ShortcutPreferenceSync', 'ShortcutStore.didFail',
                         'KeysShortcutInputOwner', 'FocusRing('):
            self.assertIn(required, source)
        app = (ROOT / 'Sources/PerchApp/App/AppDelegate.swift').read_text()
        self.assertIn('SettingsGeneralPane.connect(store: store)', app)

    def test_general_has_light_dark_snapshot_registration(self):
        shots = (ROOT / 'scripts/redesign_shots.list').read_text()
        self.assertIn('settings-general --scenario empty --open settings/general', shots)
        self.assertIn('light/dark', shots)


if __name__ == '__main__':
    unittest.main()
