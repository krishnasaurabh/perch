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

    def test_unavailable_task_keeps_an_explicit_exit(self):
        unavailable = self.source.split('"Task unavailable"', 1)[1].split("private struct TaskDetailsEditor", 1)[0]
        self.assertIn('Button("Close")', unavailable)
        self.assertIn(".keyboardShortcut(.cancelAction)", unavailable)
        self.assertIn('"details-close"', unavailable)

    def test_footer_is_reserved_outside_scrolling_form(self):
        self.assertIn("ScrollView", self.source)
        self.assertIn(".safeAreaInset(edge: .bottom", self.source)
        self.assertNotIn(".frame(width: 460)", self.source)

    def test_native_hosts_enable_the_swiftui_accessibility_tree(self):
        native = (ROOT / "Tests/PerchAppTests/TaskDetailsViewTests.swift").read_text()
        # Both the direct geometry host and the presented sheet need the public
        # environment override; native AppKit children alone lack SwiftUI IDs.
        self.assertEqual(native.count(r".environment(\.accessibilityEnabled, true)"), 2)

    def test_historical_title_is_not_editable(self):
        self.assertIn(".disabled(readOnly)", self.source)
        self.assertIn('Text(draft.title)', self.source)


if __name__ == "__main__":
    unittest.main()
