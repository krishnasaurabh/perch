"""Guard native-only parking API contracts in the portable architecture suite."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class ParkingNativeAPIContractTests(unittest.TestCase):
    def test_modifier_aware_return_handler_uses_the_keypress_overload(self):
        source = (ROOT / 'Sources/PerchApp/Workspace/ParkingLotCard.swift').read_text()
        self.assertIn('.onKeyPress(.return, phases: .down) { key in', source)
        self.assertIn('guard key.modifiers == .command else { return .ignored }', source)
        self.assertNotIn('.onKeyPress(.return) { key in', source)

    def test_preview_routes_undo_and_redo_to_separate_store_methods(self):
        source = (ROOT / 'Sources/PerchApp/Workspace/ParkingLotCard.swift').read_text()
        self.assertIn('onUndo: { redo in redo ? app.store.redo() : app.store.undo() }', source)
        self.assertNotIn('app.store.undo(redo:', source)


if __name__ == '__main__':
    unittest.main()
