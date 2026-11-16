"""Source contracts for observational dashboard focus diagnostics, not native UI tests."""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
PROBE = ROOT / "scripts/integration_probe.swift"
SHELL = ROOT / "Sources/PerchApp/Settings/DashboardView.swift"


class DashboardFocusTraceTests(unittest.TestCase):
    def test_diagnostic_walk_precedes_unchanged_behavior_sequence(self):
        source = PROBE.read_text()
        trace = source.split("func traceDashboardTraversal(", 1)[1].split(
            "func checkDashboardMatrix(", 1
        )[0]
        self.assertIn('DashboardWindow.show(store: fixture.store, tab: .yourWeek)', trace)
        self.assertIn('window.makeFirstResponder(window)', trace)
        self.assertLess(trace.index('window.makeFirstResponder(window)'), trace.index('"reset"'))
        self.assertIn('for index in 1...4', trace)
        self.assertIn('await matrixKey(window, 48, "\\t")', trace)
        self.assertIn('window.close()', trace)
        self.assertNotIn('matrixRequire', trace)
        behavior = source.split("func checkDashboardMatrix(", 1)[1].split(
            "func checkWelcomeMatrix(", 1
        )[0]
        self.assertLess(behavior.index('try await traceDashboardTraversal'),
                        behavior.index('DashboardWindow.show'))
        self.assertLess(behavior.index('window.makeFirstResponder(window)'),
                        behavior.index('await matrixKey(window, 48, "\\t")'))
        self.assertIn('window.firstResponder === DashboardKeyLoop.tabKeyView(in: window)', behavior)
        for label in (
            'Tab enters the dashboard tab control',
            'Tab moves from the tabs to the history search',
            'typed history search filters the task lines',
            'Shift-Tab returns focus to the dashboard tabs',
            'Space on Delete project deletes the project',
            'project deletion persists and keeps its tasks',
            'Command-Z restores the deleted project and its task links',
        ):
            self.assertIn(label, behavior)

    def test_trace_names_semantics_and_bounded_native_links(self):
        source = PROBE.read_text()
        diagnostic = source.split('struct DashboardFocusTrace', 1)[1].split(
            'func traceDashboardTraversal(', 1
        )[0]
        for field in ('accessibilityRole', 'accessibilityIdentifier',
                      'accessibilityLabel', 'accessibilityTitle', 'accessibilityValue',
                      'accessibilityParent', 'accessibilityChildren', 'accessibilityChildrenInNavigationOrder',
                      'accessibilityFocusedUIElement', 'isAccessibilityFocused',
                      'nextKeyView', 'previousKeyView', 'nextValidKeyView',
                      'tabKeyView', 'ObjectIdentifier', 'contentView'):
            self.assertIn(field, diagnostic)
        self.assertIn('depth < 24', diagnostic)
        self.assertIn('nodes.count < 256', diagnostic)
        self.assertIn('chain.count < 64', diagnostic)
        self.assertIn('@convention(c) (AnyObject, Selector) -> Bool', diagnostic)
        self.assertNotIn('makeFirstResponder', diagnostic)
        self.assertNotIn('setAccessibility', diagnostic)

    def test_tab_container_has_a_stable_diagnostic_identifier(self):
        shell = SHELL.read_text()
        self.assertIn('.accessibilityIdentifier("dashboard-tabs")', shell)
        self.assertIn('view.setAccessibilityIdentifier("dashboard-tabs-host")', shell)


if __name__ == '__main__':
    unittest.main()
