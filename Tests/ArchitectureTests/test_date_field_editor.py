"""The date editor emits values; it never reaches into planner state."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
EDITOR = ROOT / "Sources/PerchApp/Workspace/DateFieldEditor.swift"
DRAFT = ROOT / "Sources/PerchUI/DateFieldDraft.swift"


class DateFieldEditorTests(unittest.TestCase):
    def test_editor_has_no_planner_store_access(self):
        source = EDITOR.read_text()
        for forbidden in ("PlannerStore", "EnvironmentObject", "store.", ".apply", "updateTask", "PlannerEngine"):
            self.assertNotIn(forbidden, source)

    def test_editor_reports_through_explicit_callbacks(self):
        source = EDITOR.read_text()
        self.assertIn("var onCommit: ((DateFieldDraft.Commit) -> Void)?", source)
        self.assertIn("var onCancel: (() -> Void)?", source)
        self.assertIn("draft.revert()", source)

    def test_editor_uses_a_real_date_picker_and_adapts_to_width(self):
        source = EDITOR.read_text()
        self.assertIn("DatePicker(", source)
        self.assertIn("ViewThatFits(in: .horizontal)", source)

    def test_every_control_has_a_label_identifier_and_focus_binding(self):
        source = EDITOR.read_text()
        for control in ("text", "picker"):
            self.assertIn(f"DateFieldControl.{control}.accessibilityLabel", source)
            self.assertIn(f"DateFieldControl.{control}.identifier", source)
            self.assertIn(f".focused($focus, equals: .{control})", source)
        for control in ("add", "clear", "cancel", "commit"):
            self.assertRegex(source, rf"button\(\.{control},")
        self.assertIn(".focused($focus, equals: control)", source)

    def test_draft_is_portable_and_never_mutates_its_original(self):
        source = DRAFT.read_text()
        self.assertNotRegex(source, r"import (SwiftUI|AppKit)")
        self.assertIn("public let original: DayKey?", source)


if __name__ == "__main__":
    unittest.main()
