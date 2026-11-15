"""Phone mode reflects the separate consent ledger without becoming an Undo edit."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
PANE = ROOT / 'Sources/PerchApp/Settings/SettingsCalendarPane.swift'
SYNC = ROOT / 'Sources/PerchApp/Services/RemindersSync.swift'


def method(source, name):
    match = re.search(rf'func {name}\b[^{{]*\{{', source)
    if match is None:
        raise AssertionError(f'Missing method: {name}')
    start, depth = match.end(), 1
    for index in range(start, len(source)):
        depth += (source[index] == '{') - (source[index] == '}')
        if depth == 0:
            return source[start:index]
    raise AssertionError(f'Unclosed method: {name}')


class CalendarPhoneConsentTests(unittest.TestCase):
    def test_phone_mode_writes_do_not_add_undo_entries(self):
        source = PANE.read_text()
        for name in ('setPhoneEdits', 'reflectExistingPhoneConsent'):
            body = method(source, name)
            self.assertIn('save(.phoneEdits(value), origin: .background)', body)
        self.assertIn('store.performMutation(origin: origin)', source)
        self.assertIn('origin: PlannerCommandOrigin = .user', source)

    def test_history_and_external_changes_refresh_the_same_read_only_path(self):
        source = PANE.read_text()
        for event in ('store.planner', 'sync.twoWayEnabled'):
            self.assertRegex(source, rf'\.onChange\(of: {re.escape(event)}\)\s*\{{[^}}]*model.refreshPhoneConsent\(\)')
        for event in ('NSApplication.didBecomeActiveNotification', '.EKEventStoreChanged'):
            self.assertRegex(source, rf'publisher\(for: {re.escape(event)}\)\)\s*\{{ _ in\s*Task \{{\s*await permissions.refresh\(\)\s*await model.refreshPhoneConsent\(\)')
        self.assertIn('readPhoneConsent: { await effects.readPhoneConsent() }', source)
        self.assertIn('services.remindersSync.refreshTwoWayConsent()', source)
        self.assertIn('reflectExistingPhoneConsent(enabled)', method(source, 'refreshPhoneConsent'))

    def test_ledger_refresh_never_changes_consent_or_resumes_sync(self):
        body = method(SYNC.read_text(), 'refreshTwoWayConsent')
        self.assertIn('try reconciler.twoWayEnabled()', body)
        self.assertIn('twoWayEnabled = enabled', body)
        for write in ('setTwoWayEnabled(', '.enable(', '.disable(', '.save(', 'sync()', 'pausedForHistory ='):
            self.assertNotIn(write, body)
        reflection = method(PANE.read_text(), 'reflectExistingPhoneConsent')
        self.assertNotIn('setTwoWay(', reflection)


if __name__ == '__main__':
    unittest.main()
