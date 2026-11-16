"""Keep checklist identity, scroll setup, and snapshot delivery contracts intact."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKSPACE = ROOT / "Sources/PerchApp/Workspace"


class ChecklistNativeRegressions(unittest.TestCase):
    def test_composite_containers_do_not_override_the_checklist_identity(self):
        home = (WORKSPACE / "HomePage.swift").read_text()
        card = (WORKSPACE / "TasksCard.swift").read_text()
        slot = home.split("TasksCard()", 1)[1].split("VStack(", 1)[0]
        self.assertNotIn(".accessibilityIdentifier(", slot)
        # A GeometryReader's identifier also propagates to its hosted controls.
        viewport = card.split("GeometryReader { viewport in", 1)[1].split("Spacer(minLength:", 1)[0]
        self.assertNotIn('.accessibilityIdentifier("today-task-viewport")', viewport)
        self.assertIn('.accessibilityIdentifier("today-checklist")', viewport)
        self.assertEqual(viewport.count('.focusable(!tasks.isEmpty)'), 1)
        self.assertIn('.focused($focus, equals: .checklist)', viewport)
        marker = card.split('private struct TasksContinuationObserver:', 1)[1].split('struct TaskComposer:', 1)[0]
        self.assertIn('enclosing.setAccessibilityIdentifier("today-task-viewport")', marker)

    def test_card_restores_its_boundary_without_recoloring_the_current_task(self):
        card = (WORKSPACE / "TasksCard.swift").read_text()
        block = (WORKSPACE / "CurrentTaskBlock.swift").read_text()
        self.assertIn('.card(.tasks, padding: Theme.Size.cardPadding.value)', card)
        self.assertIn('.background(Theme.paper)', card)
        self.assertIn('.fill(Theme.butter)', block)
        self.assertIn('.strokeBorder(Theme.edge(.butter)', block)

    def test_first_tab_trace_is_printed_before_the_original_assertion(self):
        probe = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        traversal = probe.split("func focusByTab(", 1)[1].split("func recordTextUndo(", 1)[0]
        for field in ('"element"', '"role"', '"identifier"', '"selected"', '"focused"'):
            self.assertIn(field, traversal)
        self.assertIn('"TAB FOCUS "', traversal)
        self.assertLess(traversal.index('"TAB FOCUS "'), traversal.index('isFocused(node) {'))
        self.assertIn('require(reached, "\\(name): Tab reaches the single checklist stop")', probe)
        self.assertIn('"\\(name): Tab leaves the checklist in one step"', probe)

    def test_compact_probe_restarts_at_the_top_after_disclosure(self):
        probe = (ROOT / "scripts/compact_home_probe.swift").read_text()
        dense = probe.split('if scenario == "dense", let document = list.documentView {', 1)[1].split(
            'if scenario == "long-title"', 1)[0]
        self.assertLess(dense.index('"dense: later disclosure opens"'), dense.index('scrollToTaskOrigin(list)'))
        self.assertLess(dense.index('scrollToTaskOrigin(list)'), dense.index('let expandedCapture ='))
        self.assertIn('controlFrame("Add a task", in: root) == expandedCapture', dense)
        widths = probe.split('"\\(name): later rows open"', 1)[1]
        self.assertLess(widths.index('scrollToTaskOrigin(list)'), widths.index('"\\(name): fade visible during overflow"'))
        self.assertIn('document.isFlipped ? document.bounds.minY : document.bounds.maxY', probe)
        self.assertIn('"\\(name): dense capture unchanged"', widths)
        self.assertIn('cue.frame.height == 20', widths)

    def test_snapshot_timeout_and_upload_exclude_only_rotating_backups(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        shot_step = workflow.split('- name: Redesign snapshots (', 1)[1].split('- name: Upload redesign snapshots', 1)[0]
        self.assertRegex(shot_step, r'timeout-minutes:\s*15\b')
        upload = workflow.split('- name: Upload redesign snapshots', 1)[1].split('- name:', 1)[0]
        self.assertIn('${{ runner.temp }}/redesign-shots', upload)
        self.assertIn('!**/planner.json.backups/**', upload)
        self.assertIn('if-no-files-found: error', upload)


if __name__ == "__main__":
    unittest.main()
