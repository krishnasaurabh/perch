"""Keep Calendar settings builders and typed bindings small and explicit."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Sources/PerchApp/Settings/SettingsCalendarPane.swift'


def declaration(source, name):
    match = re.search(rf'private struct {name}\b[^{{]*\{{', source)
    if match is None:
        raise AssertionError(f'Missing view or adapter: {name}')
    start = match.end()
    depth = 1
    for index in range(start, len(source)):
        depth += (source[index] == '{') - (source[index] == '}')
        if depth == 0:
            return source[start:index]
    raise AssertionError(f'Unclosed declaration: {name}')


class CalendarSettingsStructureTests(unittest.TestCase):
    def test_content_composes_three_small_section_views(self):
        source = SOURCE.read_text()
        content = declaration(source, 'SettingsCalendarContent')
        self.assertNotIn('SettingsRow(', content)
        for name in ('CalendarMeetingSettings', 'CalendarReminderSettings', 'CalendarMirroringSettings'):
            self.assertIn(f'{name}(', content)
            section = declaration(source, name)
            self.assertEqual(section.count('SettingsSection('), 1)
            self.assertLessEqual(len(section.splitlines()), 100)

    def test_segmented_bindings_have_explicit_value_types_and_forwarding_setters(self):
        source = SOURCE.read_text()
        for value_type, setter in (
            ('HeadsUpInterval', 'setMeetingHeadsUp'),
            ('SnoozeDuration', 'setSnoozeDuration'),
            ('PhoneEditPolicy', 'setPhoneEdits'),
        ):
            self.assertIn(f'Binding<{value_type}>', source)
            self.assertNotIn(f'set: model.{setter}', source)
        self.assertIn('set: { model.setSnoozeDuration($0) }', source)

    def test_service_effects_are_explicit_functions_outside_view_initialization(self):
        source = SOURCE.read_text()
        adapter = declaration(source, 'CalendarSettingsEffects')
        for signature in (
            'func refreshCalendar() -> Void',
            'func enableMirroring() async -> Bool',
            'func setTwoWay(_ enabled: Bool) -> Bool',
            'func refreshReminders() -> Void',
            'func refreshMirroring() -> Void',
        ):
            self.assertIn(signature, adapter)
        content = declaration(source, 'SettingsCalendarContent')
        self.assertNotIn('services.remindersSync.setTwoWayEnabled', content)
        for function in ('refreshCalendar', 'enableMirroring', 'setTwoWay', 'refreshReminders', 'refreshMirroring'):
            self.assertIn(f'effects.{function}(', content)


if __name__ == '__main__':
    unittest.main()
