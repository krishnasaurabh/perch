"""Repeat picker contract: a draft-only editor with labelled, keyboard-reachable controls."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
VIEW = ROOT / "Sources/PerchApp/Workspace/RepeatPickerEditor.swift"
DRAFT = ROOT / "Sources/PerchUI/RepeatPickerDraft.swift"


class RepeatPickerContractTests(unittest.TestCase):
    def setUp(self):
        self.view = VIEW.read_text()
        self.draft = DRAFT.read_text()

    def test_editor_never_mutates_the_planner(self):
        # The draft may build an action value; neither file may hold or run a planner.
        for source in (self.view, self.draft):
            self.assertNotRegex(source, r"\bPlannerStore\b|\bPlannerEngine\b|\bstore\.|EnvironmentObject|\.execute\(")
            self.assertNotRegex(source, r"\bmutating func \w+\([^)]*inout Planner")
        self.assertIn("let onCommit: (RepeatPickerDraft.Commit) -> Void", self.view)
        self.assertIn("let onCancel: () -> Void", self.view)

    def test_cancel_reverts_and_done_requires_a_valid_draft(self):
        cancel = re.search(r"private func cancel\(\) \{(.*?)\n    \}", self.view, re.S)
        self.assertIsNotNone(cancel)
        self.assertLess(cancel.group(1).index("draft.revert()"), cancel.group(1).index("onCancel()"))
        commit = re.search(r"private func commit\(\) \{(.*?)\n    \}\n", self.view, re.S)
        self.assertIsNotNone(commit)
        self.assertIn("guard let result = draft.commit() else", commit.group(1))
        self.assertIn(".keyboardShortcut(.cancelAction)", self.view)
        self.assertIn(".keyboardShortcut(.defaultAction)", self.view)

    def test_controls_are_labelled_and_focusable(self):
        for label in ('"Repeat"', '"Repeat interval"', '"Repeat unit"', '"Repeat on"', '"Count from completion"'):
            self.assertIn(label, self.view)
        for identifier in ("repeat-frequency", "repeat-interval", "repeat-unit", "repeat-weekday-",
                           "repeat-from-completion", "repeat-error", "repeat-preview", "repeat-cancel",
                           "repeat-done"):
            self.assertIn(f'"{identifier}', self.view)
        self.assertIn(".defaultFocus($focus, .frequency)", self.view)
        for focus in (".frequency", ".interval", ".unit", ".weekday(weekday)", ".fromCompletion"):
            self.assertIn(f".focused(focus, equals: {focus})", self.view)
        self.assertIn("RepeatPickerDraft.localizedWeekdayNames(locale: locale)[weekday - 1]", self.view)

    def test_errors_are_inline_and_compact_layouts_reflow(self):
        self.assertIn("draft.visibleIssue", self.view)
        self.assertIn("StatusLabel(title: issue.message, tone: .danger)", self.view)
        self.assertGreaterEqual(self.view.count("ViewThatFits(in: .horizontal)"), 2)
        self.assertIn("RepeatPickerLayout.compactMinimumWidth", self.view)

    def test_standalone_editor_preserves_the_series_anchor(self):
        self.assertIn("seriesAnchor: DayKey? = nil", self.view)
        self.assertIn("original: original, anchor: anchor, seriesAnchor: seriesAnchor, calendar: calendar", self.view)

    def test_only_frequencies_the_core_model_supports(self):
        cases = re.search(r"case (none, daily.*)\n", self.draft).group(1)
        self.assertEqual([c.strip() for c in cases.split(",")],
                         ["none", "daily", "weekdays", "weekly", "monthly", "quarterly", "yearly", "custom"])
        units = re.search(r"enum Unit: String, Codable, Sendable \{ case (.*?) \}",
                          (ROOT / "Sources/PlannerCore/TaskRepeat.swift").read_text()).group(1)
        self.assertEqual(units, "day, week, month")


if __name__ == "__main__":
    unittest.main()
