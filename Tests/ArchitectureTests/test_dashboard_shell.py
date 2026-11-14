"""Contracts for the shared window shell and its independent tab bodies."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
APP = ROOT / "Sources/PerchApp"


class DashboardShellTests(unittest.TestCase):
    def test_shell_uses_foundations_and_three_independent_bodies(self):
        source = (APP / "Settings/DashboardView.swift").read_text()
        for required in ("DotGridSheet(.window)", "PerchSegmented(",
                         ".perchFont(.windowTitle)", "YourWeekView()",
                         "HistoryView()", "ProjectsView()"):
            self.assertIn(required, source)
        self.assertNotIn("UpcomingList", source)
        self.assertNotIn(".pickerStyle(.segmented)", source)
        self.assertFalse((APP / "Settings/UpcomingList.swift").exists())
        for name, legacy in (("YourWeek", "InsightsDashboard"),
                             ("History", "HistoryList"), ("Projects", "ProjectsList")):
            body = (APP / f"Settings/{name}View.swift").read_text()
            self.assertIn(f"struct {name}View: View", body)
            self.assertIn(f"{legacy}()", body)
            self.assertIn("static func subtitle", body)

    def test_existing_preview_targets_and_each_empty_state_remain_registered(self):
        source = (APP / "App/AppDelegate+Preview.swift").read_text()
        shots = (ROOT / "scripts/redesign_shots.list").read_text()
        for target, tab in (("your-week", "yourWeek"), ("history", "history"), ("projects", "projects")):
            self.assertIn(f'"{target}": .window("dashboard")', source)
            self.assertIn(f"tab: .{tab}", source)
            self.assertIn(f"{target}-empty --scenario empty --open {target}", shots)

    def test_menu_and_keyboard_bridge_use_the_shared_window(self):
        source = (APP / "Settings/DashboardView.swift").read_text()
        workspace = (APP / "Workspace/WorkspaceView.swift").read_text()
        self.assertIn("DashboardWindow.installMenuItems(in: menu, open: dashboard)", workspace)
        self.assertIn("open()", source)
        self.assertIn("selection?.tab = tab", source)
        self.assertIn("tabs.nextKeyView = search", source)
        self.assertIn("search.nextKeyView", source)
        self.assertIn("onUndo:", source)
        self.assertIn("store.redo() : store.undo()", source)


if __name__ == "__main__":
    unittest.main()
