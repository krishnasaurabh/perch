"""Task details keep edits local until an explicit, typed save."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class TaskDetailsBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.source = (ROOT / "Sources/PerchApp/Workspace/TaskDetailsSheet.swift").read_text()

    def test_details_never_autosave_or_mutate_task_fields(self):
        for forbidden in ("store.updateTask", "store.setText", "store.flushPendingText", "WritableKeyPath"):
            self.assertNotIn(forbidden, self.source)

    def test_explicit_save_and_cancel(self):
        self.assertIn('Button("Cancel")', self.source)
        self.assertIn('Button("Save")', self.source)
        self.assertIn(".keyboardShortcut(.cancelAction)", self.source)
        self.assertIn(".keyboardShortcut(.defaultAction)", self.source)

    def test_footer_is_reserved_outside_scrolling_form(self):
        self.assertIn("ScrollView", self.source)
        self.assertIn(".safeAreaInset(edge: .bottom", self.source)
        self.assertNotIn(".frame(width: 460)", self.source)

    def test_historical_title_is_not_editable(self):
        self.assertIn(".disabled(readOnly)", self.source)
        self.assertIn('Text(draft.title)', self.source)


if __name__ == "__main__":
    unittest.main()
