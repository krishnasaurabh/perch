"""English extraction, pseudolocalization and parser-language boundaries."""
import json
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
FORMATS = re.compile(r'%(?:\d+\$)?(?:@|lld|d|f|\.\d+f)')


class LocalizationTests(unittest.TestCase):
    def test_catalogs_are_fresh_and_identical_to_their_portable_copies(self):
        subprocess.run(['python3', 'scripts/update_localization.py', '--check'], cwd=ROOT, check=True)
        for target in ('PerchUI', 'PerchApp'):
            directory = ROOT / 'Sources' / target / 'Resources'
            self.assertEqual((directory / 'Localizable.xcstrings').read_bytes(),
                             (directory / 'Localizable.json').read_bytes())
        self.assertEqual((ROOT / 'Sources/PerchApp/Resources/Localizable.xcstrings').read_bytes(),
                         (ROOT / 'Resources/Localizable.xcstrings').read_bytes())

    def test_every_catalog_key_has_english_and_expanded_pseudolocalization(self):
        for path in (ROOT / 'Sources/PerchUI/Resources/Localizable.xcstrings',
                     ROOT / 'Sources/PerchApp/Resources/Localizable.xcstrings'):
            document = json.loads(path.read_text())
            self.assertEqual(document['sourceLanguage'], 'en')
            self.assertGreater(len(document['strings']), 50)
            for key, entry in document['strings'].items():
                localizations = entry['localizations']
                self.assertEqual(set(localizations), {'en', 'zz'}, key)
                def values(localization):
                    if 'stringUnit' in localization:
                        return [localization['stringUnit']['value']]
                    plural = localization['variations']['plural']
                    return [plural[category]['stringUnit']['value'] for category in sorted(plural)]
                english_values = values(localizations['en'])
                for language, localization in localizations.items():
                    for index, value in enumerate(values(localization)):
                        self.assertTrue(set(FORMATS.findall(value)).issubset(set(FORMATS.findall(key))), key)
                        if language == 'zz':
                            self.assertTrue(value.startswith('⟦') and value.endswith(' ·~⟧'), key)
                            self.assertGreater(len(value), len(english_values[index]), key)

    def test_all_interactive_capture_paths_validate_language_before_mutation(self):
        store = (ROOT / 'Sources/PerchApp/App/PlannerStore.swift').read_text()
        self.assertIn('guard let supported = parserLanguage() else', store)
        self.assertIn('return apply { try $0.addTasks(titles, on: day, literal: literal, language: language) }', store)
        for relative in ('Workspace/TasksCard.swift', 'Workspace/WeekPage.swift', 'Workspace/HomeCards.swift'):
            text = (ROOT / 'Sources/PerchApp' / relative).read_text()
            self.assertNotIn('try $0.addTasks', text, relative)
            self.assertIn('store.addTasks', text, relative)
        language = (ROOT / 'Sources/PlannerCore/TaskParserLanguage.swift').read_text()
        self.assertIn('case english = "en"', language)
        self.assertIn('throw UnsupportedTaskParserLanguage', language)

    def test_language_status_and_long_localized_help_wrap(self):
        settings = (ROOT / 'Sources/PerchApp/Settings/SettingsView.swift').read_text()
        self.assertIn('Section("Language")', settings)
        self.assertIn('Task entry parser', settings)
        self.assertGreaterEqual(settings.count('.fixedSize(horizontal: false, vertical: true)'), 2)


if __name__ == '__main__':
    unittest.main()
