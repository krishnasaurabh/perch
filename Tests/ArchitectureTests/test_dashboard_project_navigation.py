"""Dashboard focus and exact history-evidence contracts; native tests run on macOS."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DashboardProjectNavigationTests(unittest.TestCase):
    def test_project_deletion_is_reachable_from_the_visible_options_control(self):
        shell = (ROOT / 'Sources/PerchApp/Settings/DashboardView.swift').read_text()
        projects = (ROOT / 'Sources/PerchApp/Settings/ProjectsList.swift').read_text()
        view = (ROOT / 'Sources/PerchApp/Settings/ProjectsView.swift').read_text()
        combined = shell + projects + view
        # Every card carries a visible, accessible options control that reveals both
        # actions; the destructive action is never only a bare control on the page.
        self.assertIn('project-options-\\(project.id.uuidString)', projects)
        self.assertIn('AppL10n.text("Project options")', projects)
        self.assertIn('PerchButton("Rename project"', projects)
        self.assertIn('.contextMenu', projects)
        self.assertIn('Button("Delete project", action: delete)', projects)
        self.assertIn('project-new', projects)

    def test_project_actions_are_linked_only_for_projects(self):
        shell = (ROOT / 'Sources/PerchApp/Settings/DashboardView.swift').read_text()
        self.assertIn('host.selectionState?.tab == .projects', shell)
        self.assertIn('DashboardProjectActionView', shell)
        self.assertIn('tabs.nextKeyView = first', shell)
        self.assertIn('action.nextKeyView =', shell)
        self.assertIn('action.canBecomeKeyView', shell)

    def test_history_uses_exact_ax_values_not_ocr(self):
        probe = (ROOT / 'scripts/integration_probe.swift').read_text()
        check = probe.split('func checkDashboardMatrix(', 1)[1].split('func checkWelcomeMatrix(', 1)[0]
        self.assertIn('field?.accessibilityValue() as? String == "alpha"', check)
        self.assertIn('filtered.contains("Matrix history alpha")', check)
        self.assertIn('!filtered.contains("Matrix history beta")', check)
        self.assertIn('let filtered = try dashboardAXStaticText(host)', check)
        self.assertNotIn('filtered = try matrixText', check)
        helper = probe.split('func dashboardAXStaticText(', 1)[1].split('struct DashboardFocusTrace', 1)[0]
        for selector in ('accessibilityChildren', 'accessibilityContents', 'accessibilityChildrenInNavigationOrder'):
            self.assertIn(selector, helper)
        self.assertIn('view.subviews', helper)
        self.assertIn('AXStaticText', helper)
        self.assertNotIn('lowercased()', helper)

    def test_project_observations_keep_the_single_tab_options_sequence(self):
        probe = (ROOT / 'scripts/integration_probe.swift').read_text()
        check = probe.split('// Project action: the card', 1)[1].split('func checkWelcomeMatrix(', 1)[0]
        self.assertLess(check.index('matrixKey(window, 48'), check.index('behavior-project-tab'))
        self.assertLess(check.index('behavior-project-tab'), check.index('MatrixControls.projectOptions'))
        self.assertLess(check.index('MatrixControls.projectOptions'), check.index('performClick(nil)'))
        self.assertNotIn('store.apply', check)
        self.assertNotIn('fixture.store.apply', check)
        self.assertIn('Tab reaches the project options control on the card', check)
        self.assertIn('the card page never hosts a bare Delete project control', check)
        self.assertIn('the project options surface offers Delete project', check)
        self.assertIn("Delete project from the card's options deletes the project", check)
        self.assertIn('project deletion persists and keeps its tasks', check)
        self.assertIn('project deletion removes no task', check)
        self.assertIn('Command-Z restores the deleted project and its task links', check)
        self.assertIn('tabNextValidKeyViewChain', probe)
        self.assertIn('firstResponderLabel', probe)
        self.assertIn('firstResponderIdentifier', probe)


if __name__ == '__main__':
    unittest.main()
