"""Today keeps actions discoverable and capture outside the task scroller."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKSPACE = ROOT / "Sources/PerchApp/Workspace"


class TodayInteractionTests(unittest.TestCase):
    def test_row_actions_do_not_depend_on_hover_or_swipe(self):
        path = WORKSPACE / "TaskRow.swift"
        source = path.read_text() if path.exists() else (WORKSPACE / "TasksCard.swift").read_text()
        self.assertNotIn("if hover", source)
        self.assertNotIn("DragGesture", source)
        for identifier in ("task-complete-", "task-details-", "task-delete-"):
            self.assertIn(identifier, source)
        self.assertIn("Theme.minimumTarget", source)
        self.assertIn("ControlFocusRing", source)

    def test_priority_is_textual_and_includes_medium_and_low(self):
        path = WORKSPACE / "TaskRow.swift"
        source = path.read_text() if path.exists() else (WORKSPACE / "TasksCard.swift").read_text()
        self.assertIn("task.priority != .none", source)
        self.assertIn("task.priority.rawValue.capitalized", source)
        self.assertIn("Theme.priority(task.priority)", source)
        self.assertNotIn("lineLimit(compact ? 1 : 2)", source)

    def test_capture_and_undo_follow_the_list_viewport(self):
        source = (WORKSPACE / "TasksCard.swift").read_text()
        self.assertLess(source.index("GeometryReader"), source.index("TaskComposer("))
        self.assertIn('accessibilityIdentifier("today-undo")', source)
        self.assertIn(".upArrow", source)
        self.assertIn(".downArrow", source)
        self.assertIn("TodayTaskNavigation", source)

    def test_overdue_policy_is_not_a_persistent_home_banner(self):
        source = "\n".join(p.read_text() for p in WORKSPACE.glob("*.swift"))
        self.assertNotIn("OverdueBanner()", source)
        self.assertNotIn('Picker(\n                "Overdue tasks"', source)
        self.assertIn('accessibilityIdentifier("today-review-overdue")', source)


if __name__ == "__main__":
    unittest.main()
