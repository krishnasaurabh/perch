"""Source boundaries for the review windows; native geometry is checked on macOS."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "Sources/PerchApp/Settings"


class ReviewWindowContracts(unittest.TestCase):
    def test_screen_bodies_consume_foundations_without_a_second_window_shell(self):
        for name in ("YourWeekView.swift", "HistoryList.swift", "ProjectsList.swift"):
            source = (APP / name).read_text()
            self.assertNotIn("DotGridSheet", source, name)
            self.assertNotIn("ViewThatFits", source, name)
            self.assertNotRegex(source, r"Color\(hex:")
            self.assertNotRegex(source, r"\.font\(\.system\(size:")
            self.assertNotRegex(source, r"\.animation\(\.(?:spring|easeOut|linear)")
            self.assertIn(".perchFont(", source)
            self.assertIn("Card(", source)

    def test_models_remain_portable_and_do_not_mutate_storage(self):
        for name in ("YourWeekModel", "HistoryModel"):
            source = (ROOT / f"Sources/PerchUI/{name}.swift").read_text()
            self.assertNotRegex(source, r"import (SwiftUI|AppKit)")
            self.assertNotIn("PlannerFile", source)
            self.assertIn("engine: PlannerEngine", source)

    def test_filter_and_project_edit_states_have_registered_shots(self):
        shots = (ROOT / "scripts/redesign_shots.list").read_text()
        registry = (ROOT / "Sources/PerchApp/App/AppDelegate+Preview.swift").read_text()
        for target in ("history-carried", "history-time", "history-agent",
                       "projects-new", "projects-rename", "projects-options"):
            self.assertIn(f"--open {target}", shots)
            self.assertRegex(registry, re.escape(f'"{target}": .window("dashboard")'))
        self.assertIn("your-week-carried --scenario window-review --open your-week", shots)

    def test_filing_uses_typed_identities_and_one_undo_transaction(self):
        source = (APP / "ProjectsList.swift").read_text()
        self.assertIn(".dropDestination(for: TaskDragItem.self)", source)
        self.assertIn("return store.apply { commands in", source)
        self.assertIn("commands.updateTask(item.taskID)", source)
        self.assertIn("$0.projectID = projectID", source)
        self.assertIn(".contextMenu", source)
        self.assertIn('Button("Rename project"', source)
        self.assertIn('Button("Delete project"', source)
        self.assertIn(".popover(isPresented: $options)", source)
        self.assertIn("ProjectDeleteButton", source)
        self.assertIn("DashboardProjectActionView", source)

    def test_chart_height_can_grow_and_week_rollover_releases_priority_slots(self):
        source = (APP / "YourWeekView.swift").read_text()
        self.assertIn(".frame(minHeight: ReviewMetrics.chartHeight", source)
        self.assertIn(".onChange(of: value.nextWeekStart)", source)
        self.assertIn("added = [:]", source)
        self.assertIn("literal: true", source)
        self.assertFalse((APP / "InsightsDashboard.swift").exists())

    def test_history_respects_attribution_visibility_without_changing_filter_metadata(self):
        view = (APP / "HistoryList.swift").read_text()
        model = (ROOT / "Sources/PerchUI/HistoryModel.swift").read_text()
        self.assertIn("store.prefs.showAgentAttribution", view)
        self.assertIn("let id = task.agentID", view)
        self.assertIn("AgentName.short(id)", view)
        self.assertIn("case .agent: return task.agentID != nil", model)


if __name__ == "__main__":
    unittest.main()
