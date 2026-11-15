"""Keep the native Undo probe on the shipping parking-lot controls."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class ParkingUndoProbeTests(unittest.TestCase):
    def setUp(self):
        self.source = (ROOT / 'scripts/undo_probe.swift').read_text()

    def test_probe_mounts_current_capture_and_review_views(self):
        self.assertNotIn('NotepadCard(', self.source)
        self.assertIn('ParkingLotCard().environmentObject(store)', self.source)
        self.assertIn('ParkedThoughtsView().environmentObject(store)', self.source)
        self.assertIn('try await checkParkingLotView(store)', self.source)

    def test_capture_uses_native_editor_and_return_before_persistence_checks(self):
        self.assertIn('field.currentEditor() as? NSTextView', self.source)
        self.assertIn('tv.didChangeText()', self.source)
        self.assertIn('keyCode: 36', self.source)
        self.assertIn('window.sendEvent(event)', self.source)
        self.assertIn('typing alone does not save a thought or create a task', self.source)
        self.assertIn('blur preserves the submitted thought', self.source)
        self.assertIn('removing the parking card preserves both submitted thoughts', self.source)

    def test_promotion_presses_the_native_action_and_checks_undo(self):
        self.assertIn('"parking-promote-\\(thought.id.uuidString)"', self.source)
        self.assertIn('NSSelectorFromString("accessibilityPerformPress")', self.source)
        self.assertIn('Undo restores the thought and removes only its promoted task', self.source)

    def test_review_host_enables_and_primes_accessibility_before_lookup(self):
        review = self.source.split('// Exercise the actual review button', 1)[1]
        host, lookup = review.split('let buttons =', 1)
        self.assertIn('import ApplicationServices', self.source)
        self.assertIn('func wakeAX() async', self.source)
        self.assertIn('AXUIElementCreateApplication(getpid())', self.source)
        self.assertIn('kAXWindowsAttribute', self.source)
        self.assertIn('kAXChildrenAttribute', self.source)
        self.assertIn('.environment(\\.accessibilityEnabled, true)', host)
        ordered = ['window.contentView =', 'window.makeKeyAndOrderFront(nil)',
                   'NSApp.activate(ignoringOtherApps: true)', 'try await settle()',
                   'await wakeAX()', 'try await settle()']
        cursor = 0
        for statement in ordered:
            found = host.find(statement, cursor)
            self.assertGreaterEqual(found, cursor, statement)
            cursor = found + len(statement)
        self.assertIn('nodes(window)', lookup)

    def test_promotion_lookup_deduplicates_identifiers_and_reports_count(self):
        lookup = self.source.split('let buttons =', 1)[1].split('let button =', 1)[0]
        self.assertIn('var seenIdentifiers = Set<String>()', self.source)
        self.assertIn('seenIdentifiers.insert(identifier).inserted', lookup)
        self.assertIn('buttons.count == 1', lookup)
        self.assertIn('found \\(buttons.count)', lookup)

    def test_legacy_storage_and_focus_probes_still_run(self):
        self.assertIn('let store = try checkStore()', self.source)
        self.assertIn('try checkDeletionRedo()', self.source)
        self.assertIn('"notepad persists on close"', self.source)
        self.assertIn('"deletion redo protects new focus credit and ledger"', self.source)


if __name__ == '__main__':
    unittest.main()
