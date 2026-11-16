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
    case.assertRegex(reader, r'\.accessibilityIdentifier\(\s*"today-task-viewport"\s*\)')
    case.assertLess(reader.index('"today-task-viewport"'), reader.index(".scrollIndicators("))
    after_inset = source.split(".safeAreaInset(edge: .bottom, spacing: 8)", 1)[1].split(
        "TaskComposer(day:", 1)[0]
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
            r'\s*\.accessibilityIdentifier\(\s*"today-task-viewport"\s*\)', "", source)
        self.assertEqual(count, 1)
        mutated = mutated.replace(
            "            TaskComposer(day:",
            '            .accessibilityIdentifier("today-task-viewport")\n            TaskComposer(day:',
            1)
        with self.assertRaises(AssertionError):
            assert_viewport_scope(self, mutated)


if __name__ == "__main__":
    unittest.main()
