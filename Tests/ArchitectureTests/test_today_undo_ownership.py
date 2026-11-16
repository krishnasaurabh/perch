"""Keep Today's Undo mount local and separate from the transient strip."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class TodayUndoOwnershipTests(unittest.TestCase):
    def test_every_edit_uses_one_stable_viewport_mount(self):
        source = (ROOT / "Sources/PerchApp/Workspace/TasksCard.swift").read_text()
        viewport = source.split(".safeAreaInset(edge: .bottom", 1)[1].split(".frame(minHeight: 0", 1)[0]
        self.assertIn("footer.modifier(NotchUndoFooter())", viewport)
        self.assertNotIn("if ", viewport)
        self.assertEqual(source.count("footer.modifier("), 1)
        self.assertEqual(source.count('accessibilityIdentifier("today-undo")'), 1)
        self.assertIn(".focused($focus, equals: .undo)", source)
        pinned = source.split("TaskComposer(day:", 1)[1].split(".card(.tasks)", 1)[0]
        self.assertNotIn("footer", pinned)
        self.assertIn("overdueFooter.fixedSize", pinned)

    def test_destination_does_not_depend_on_geometry_or_strip_lifetime(self):
        source = (ROOT / "Sources/PerchApp/Notch/NotchStrips.swift").read_text()
        footer = source.split("struct NotchUndoFooter: ViewModifier {", 1)[1].split(
            "private struct NotchUndoAction", 1)[0]
        body = footer.split("func body(content: Content)", 1)[1].split("private var inlineActivity", 1)[0]
        self.assertEqual(body.splitlines().count("            content"), 1)
        self.assertLess(body.index("            content"), body.index("if inlineActivity != nil {"))
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
