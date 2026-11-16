"""Keep Calendar's mirroring help accurate for both phone-edit policies."""
from pathlib import Path
import json
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELP = (
    "Mirroring sends tasks to your phone and watch. "
    "Completions for today's tasks come back even with Ignore. "
    "Bring back also syncs edits and deletions."
)


class CalendarMirroringHelpTests(unittest.TestCase):
    def test_visible_help_explains_completion_import_with_ignore(self):
        source = (ROOT / 'Sources/PerchApp/Settings/SettingsCalendarPane.swift').read_text()
        # Require the explanation in rendered Text, not only in a comment or catalog.
        texts = re.findall(r'Text\(\s*"([^"\n]*)"\s*\)', source)
        self.assertIn(HELP, texts)
        self.assertNotIn(
            'Mirroring sends tasks to your phone and watch. '
            'It only reads changes back if you choose Bring back.', texts)
        # Keep the existing consent mapping: Ignore is not a promise of zero imports.
        self.assertIn('guard setTwoWay(value == .bringBack)', source)

    def test_completion_and_edit_distinction_is_available_in_all_app_catalogs(self):
        for relative in (
            'Sources/PerchApp/Resources/Localizable.xcstrings',
            'Sources/PerchApp/Resources/Localizable.json',
            'Resources/Localizable.xcstrings',
        ):
            with self.subTest(catalog=relative):
                document = json.loads((ROOT / relative).read_text())
                entry = document['strings'][HELP]['localizations']
                self.assertEqual(entry['en']['stringUnit']['value'], HELP)
                self.assertTrue(entry['zz']['stringUnit']['value'])


if __name__ == '__main__':
    unittest.main()
