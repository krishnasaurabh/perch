"""Parking-lot wiring stays separate from tasks and legacy daily notes."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class ParkingLotContractTests(unittest.TestCase):
    def test_today_uses_the_unconditional_parking_card(self):
        home = (ROOT / 'Sources/PerchApp/Workspace/HomePage.swift').read_text()
        self.assertIn('ParkingLotCard()', home)
        self.assertNotIn('NotepadCard()', home)
        self.assertNotIn('hiddenWorkspaceCards', home)

    def test_parking_slot_reserves_a_rigid_height(self):
        home = (ROOT / 'Sources/PerchApp/Workspace/HomePage.swift').read_text()
        self.assertIn('ParkingLotCard().frame(height: HomeLayout.parkingHeight)', home)
        self.assertNotIn('ParkingLotCard().frame(minHeight:', home)

    def test_retired_editor_is_not_reachable(self):
        cards = (ROOT / 'Sources/PerchApp/Workspace/HomeCards.swift').read_text()
        self.assertNotIn('struct NotepadCard', cards)
        self.assertNotIn('struct ScratchpadEditor', cards)
        settings = (ROOT / 'Sources/PerchApp/Settings/SettingsView.swift').read_text()
        self.assertNotIn('var workspace:', settings)
        general = (ROOT / 'Sources/PerchApp/Settings/SettingsGeneralPane.swift').read_text()
        self.assertIn('for id in HomeLayout.ordered(store.prefs.workspaceCardOrder).filter({ $0 != "notepad" })', general)

    def test_capture_and_promotion_use_the_mutation_gateway(self):
        card = (ROOT / 'Sources/PerchApp/Workspace/ParkingLotCard.swift').read_text()
        self.assertIn('try $0.parkThought(draft)', card)
        self.assertIn('try $0.promoteThought(id, on: $0.today)', card)
        self.assertIn('onSubmit:', card)
        self.assertIn('.onKeyPress(.return, phases: .down)', card)
        self.assertIn('key.modifiers == .command', card)
        self.assertIn('Make it a task', card)
        self.assertNotIn('writeNotepad', card)
        self.assertNotIn('addTasks', card)
        self.assertNotIn('ViewThatFits', card)

    def test_card_uses_adaptive_foundation_components(self):
        card = (ROOT / 'Sources/PerchApp/Workspace/ParkingLotCard.swift').read_text()
        self.assertIn('Card(.apricot)', card)
        self.assertIn('PerchField(', card)
        self.assertIn('FocusRing(', card)
        self.assertNotIn('.system(size:', card)
        self.assertNotIn('Color(hex:', card)
        self.assertNotIn('.animation(', card)

    def test_parking_states_have_snapshot_entries(self):
        shots = (ROOT / 'scripts/redesign_shots.list').read_text()
        for name in ['parking-running', 'parking-before', 'parking-empty', 'parking-thoughts']:
            self.assertIn(name + ' --scenario ', shots)


if __name__ == '__main__':
    unittest.main()
