"""Dashboard focus and exact history-evidence contracts; native tests run on macOS."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DashboardProjectNavigationTests(unittest.TestCase):
    def test_project_action_has_one_native_target_and_no_swiftui_focus_proxy(self):
        shell = (ROOT / 'Sources/PerchApp/Settings/DashboardView.swift').read_text()
        self.assertIn('struct DashboardProjectDeleteButton: View', shell)
        control = shell.split('struct DashboardProjectDeleteButton: View', 1)[1]
        self.assertIn('DashboardProjectActionTarget(', control)
        self.assertIn('.accessibilityHidden(true)', control)
        self.assertNotIn('.focusable(', control)
        self.assertIn('final class DashboardProjectActionView: NSButton', control)
        self.assertIn('isTransparent = true', control)
        self.assertIn('!event.isARepeat', control)
        self.assertIn('event.window === window', control)
        self.assertIn('window?.isKeyWindow == true', control)
        self.assertIn('performClick(nil)', control)
        self.assertIn('isEnabled && !isHiddenOrHasHiddenAncestor', control)
        project = (ROOT / 'Sources/PerchApp/Settings/ProjectsList.swift').read_text()
        self.assertIn('DashboardProjectDeleteButton {', project)
        self.assertIn('store.apply { try $0.deleteProject(p.id) }', project)

    def test_project_actions_are_linked_only_for_projects(self):
        shell = (ROOT / 'Sources/PerchApp/Settings/DashboardView.swift').read_text()
        self.assertIn('host.selectionState?.tab == .projects', shell)
        self.assertIn('compactMap({ $0 as? DashboardProjectActionView })', shell)
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

    def test_project_observations_keep_the_single_tab_space_sequence(self):
        probe = (ROOT / 'scripts/integration_probe.swift').read_text()
        check = probe.split('// Project action: Tab to Delete project', 1)[1].split('func checkWelcomeMatrix(', 1)[0]
        self.assertLess(check.index('matrixKey(window, 48'), check.index('behavior-project-tab'))
        self.assertLess(check.index('behavior-project-tab'), check.index('matrixKey(window, 49'))
        self.assertLess(check.index('matrixKey(window, 49'), check.index('behavior-project-space'))
        self.assertNotIn('store.apply', check)
        self.assertIn('Space on Delete project deletes the project', check)
        self.assertIn('project deletion persists and keeps its tasks', check)
        self.assertIn('project deletion removes no task', check)
        self.assertIn('Command-Z restores the deleted project and its task links', check)
        self.assertIn('tabNextValidKeyViewChain', probe)
        self.assertIn('firstResponderLabel', probe)
        self.assertIn('firstResponderIdentifier', probe)


if __name__ == '__main__':
    unittest.main()
