"""Keep Today's Undo mount local and separate from the transient strip."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class TodayUndoOwnershipTests(unittest.TestCase):
    def test_completion_and_pinned_undo_mounts_are_mutually_exclusive(self):
        source = (ROOT / "Sources/PerchApp/Workspace/TasksCard.swift").read_text()
        self.assertIn("store.canUndo && model.strips?.hasCompletionUndo == true", source)
        viewport = source.split(".safeAreaInset(edge: .bottom", 1)[1].split(".frame(minHeight: 0", 1)[0]
        self.assertIn("if completionUndoVisible {", viewport)
        self.assertIn("undoFooter(reviewOverdue: false)", viewport)
        self.assertIn("NotchUndoFooter(showsUndo: !completionUndoVisible,", source)
        self.assertEqual(source.count('accessibilityIdentifier("today-undo")'), 1)
        self.assertIn(".focused($focus, equals: .undo)", source)

    def test_pinned_destination_does_not_depend_on_geometry_or_strip_lifetime(self):
        source = (ROOT / "Sources/PerchApp/Notch/NotchStrips.swift").read_text()
        footer = source.split("struct NotchUndoFooter: ViewModifier {", 1)[1].split(
            "private struct NotchUndoAction", 1)[0]
        body = footer.split("func body(content: Content)", 1)[1].split("private var inlineActivity", 1)[0]
        self.assertIn("if showsUndo {", body)
        self.assertEqual(body.splitlines().count("                    content"), 1)
        self.assertNotIn("model.geometry", body)
        self.assertNotIn("currentActivity", body)
        self.assertNotIn(".transition(", body)
        self.assertIn("if let activity = inlineActivity {", body)
        self.assertIn("if inlineActivity != nil {", body)

    def test_strip_never_borrows_today_identity_or_focus(self):
        source = (ROOT / "Sources/PerchApp/Notch/NotchStrips.swift").read_text()
        action = source.split("private struct NotchUndoAction: View {", 1)[1].split(
            "private struct NotchStripCloseButton", 1)[0]
        self.assertIn('accessibilityIdentifier("notch.undo")', action)
        self.assertNotIn("today-undo", source)
        self.assertNotIn("undoFocus", source)
        self.assertNotIn(".focused(", action)
        self.assertNotIn("FocusState", source)


if __name__ == "__main__":
    unittest.main()
