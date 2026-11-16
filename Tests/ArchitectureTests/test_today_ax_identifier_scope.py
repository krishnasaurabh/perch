"""Guard Today identifier scope; native AX roles/uniqueness are macOS probe gates."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
TASKS = ROOT / "Sources/PerchApp/Workspace/TasksCard.swift"


def assert_viewport_scope(case, source):
    # The inset is a sibling of ScrollView inside the reader's modified result.
    # An identifier on that result (or GeometryReader) also renames Undo in AX.
    reader = source.split("ScrollViewReader { scroll in", 1)[1].split(
        ".safeAreaInset(edge: .bottom, spacing: 8)", 1)[0]
    case.assertIn("TasksContinuationObserver()", reader)
    # Checklist publishes the identity on the resolved native scroller only:
    # a SwiftUI identifier would also rename its semantic checklist group.
    case.assertNotRegex(source, r'\.accessibilityIdentifier\(\s*"today-task-viewport"\s*\)')
    observer = source.split("private struct TasksContinuationObserver:", 1)[1].split(
        "enum ChecklistViewportAttachment", 1)[0]
    case.assertIn("guard let enclosing = ChecklistViewportAttachment.resolve(from: self) else {", observer)
    case.assertIn('enclosing.setAccessibilityIdentifier("today-task-viewport")', observer)
    after_inset = source.split(".safeAreaInset(edge: .bottom, spacing: 8)", 1)[1].split(
        "TaskComposer(", 1)[0]
    case.assertNotIn('"today-task-viewport"', after_inset)
    case.assertEqual(source.count('"today-task-viewport"'), 1)


class TodayAXIdentifierScopeTests(unittest.TestCase):
    def test_viewport_identifier_excludes_undo_inset(self):
        assert_viewport_scope(self, TASKS.read_text())

    def test_undo_keeps_one_mount_identity_and_focus_binding(self):
        source = TASKS.read_text()
        self.assertEqual(source.count("footer.modifier(NotchUndoFooter())"), 1)
        self.assertEqual(source.count('"today-undo"'), 1)
        self.assertEqual(source.count(".focused($focus, equals: .undo)"), 1)
        footer = source.split("private var footer: some View {", 1)[1].split(
            "@ViewBuilder private var overdueFooter", 1)[0]
        self.assertIn('.accessibilityIdentifier("today-undo")', footer)
        self.assertNotIn('"today-task-viewport"', footer)

    def test_rejects_identifier_on_inset_ancestor(self):
        source = TASKS.read_text()
        mutated, count = re.subn(
            r'\s*enclosing\.setAccessibilityIdentifier\("today-task-viewport"\)', "", source)
        self.assertEqual(count, 1)
        # Attach to GeometryReader's result, not the intervening Spacer.
        mutated, count = re.subn(
            r'(?m)^(            \.frame\(maxHeight: \.infinity, alignment: \.top\))$',
            r'\1\n            .accessibilityIdentifier("today-task-viewport")',
            mutated)
        self.assertEqual(count, 1)
        self.assertEqual(mutated.count('"today-task-viewport"'), 1)
        self.assertIn('.accessibilityIdentifier("today-task-viewport")', mutated)
        with self.assertRaises(AssertionError):
            assert_viewport_scope(self, mutated)


if __name__ == "__main__":
    unittest.main()
