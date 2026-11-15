"""Wiring checks complement portable state tests and the native key probe."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ChecklistRevisionWiringTests(unittest.TestCase):
    def test_fold_action_uses_the_existing_keyboard_owner(self):
        source = (ROOT / "Sources/PerchApp/Workspace/TasksCard.swift").read_text()
        fold = source.split("if tasks.count > TodayTaskNavigation.foldedRowCount", 1)[1].split("if tasks.isEmpty", 1)[0]
        self.assertIn("toggleFold(tasks)", fold)
        self.assertIn(".focusable(false)", fold)
        self.assertIn('focus == .checklist && foldSelected', fold)
        self.assertIn('keyboardFocused: focus == .checklist && !foldSelected', source)
        self.assertEqual(source.count('.focused($focus, equals: .checklist)'), 1)
        handler = source.split("private func handle(_ press:", 1)[1].split("struct OverdueReview", 1)[0]
        self.assertLess(handler.index("if foldSelected"), handler.index("guard let id = homeState.selectedTaskID"))
        self.assertIn("press.key == .space || press.key == .return", handler)
        self.assertIn("guard press.phase == .down", handler)
        self.assertIn("toggleFold(tasks)", handler)
        self.assertIn("TodayTaskNavigation.move(", source)
        self.assertIn("showsLater = !TodayTaskNavigation.isExpanded(", source)
        self.assertIn("let expanded = TodayTaskNavigation.isExpanded(", source)

    def test_native_probe_expands_and_collapses_without_mutation(self):
        source = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        for assertion in (
            "fresh checklist starts folded",
            "fold actions reuse the single checklist Tab stop",
            "Down reaches every task and expands later rows",
            "Space on the fold row collapses the checklist",
            "Return on the fold row expands the checklist",
            "Fold Return does not edit a task",
            "Up returns from the fold row to the last visible task",
            "Fold keyboard actions preserve persisted tasks",
        ):
            self.assertIn(assertion, source)
        self.assertIn('key(" ", code: 49, in: window)', source)
        self.assertIn('key("\\r", code: 36, in: window)', source)
        self.assertIn('store.file.load().tasks == beforeFold', source)


if __name__ == "__main__":
    unittest.main()
