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

    def test_legacy_storage_and_focus_probes_still_run(self):
        self.assertIn('let store = try checkStore()', self.source)
        self.assertIn('try checkDeletionRedo()', self.source)
        self.assertIn('"notepad persists on close"', self.source)
        self.assertIn('"deletion redo protects new focus credit and ledger"', self.source)


if __name__ == '__main__':
    unittest.main()
