"""Checklist-specific contracts, independent of the legacy time-card probes."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKSPACE = ROOT / "Sources/PerchApp/Workspace"


class ChecklistRedesignTests(unittest.TestCase):
    def test_rows_measure_once_and_share_foundation_controls(self):
        row = (WORKSPACE / "TaskRow.swift").read_text()
        for forbidden in ("ViewThatFits", "sizeThatFits(", "TitleActionsLayout", "GeometryReader"):
            self.assertNotIn(forbidden, row)
        for marker in ("PerchCheckbox(", "Theme.Size.taskRowHeight.value",
                       "Theme.Size.stepRowHeight.value", ".draggable(TaskDragItem(taskID: task.id))",
                       "Theme.carried", "Theme.ink3", "Theme.doneText"):
            self.assertIn(marker, row)
        details = row.split("private var detailText:", 1)[1].split("private var steps:", 1)[0]
        self.assertNotIn("remindAt", details)

    def test_count_order_fold_and_edit_use_shared_state(self):
        card = (WORKSPACE / "TasksCard.swift").read_text()
        for marker in ('Text("Today")', 'AppL10n.text("A fresh page")',
                       'AppL10n.format("%lld to do"', 'AppL10n.format("%lld of %lld done"',
                       'TodayTaskNavigation.ordered(', 'TodayTaskNavigation.visible(',
                       'AppL10n.format("%lld more for later today"',
                       'homeState.editingTaskID = id', '.focused($focus, equals: .checklist)'):
            self.assertIn(marker, card)
        self.assertNotIn("SegmentPills", card)
        self.assertNotIn("model.detailsTaskID", card)

    def test_current_block_is_unconditionally_open_and_tokenized(self):
        row = (WORKSPACE / "TaskRow.swift").read_text()
        block = (WORKSPACE / "CurrentTaskBlock.swift").read_text()
        self.assertIn("current ||", row)
        self.assertIn("CurrentTaskBlock(task: task)", row)
        self.assertIn("TodayTaskNavigation.nextStep(in: task.steps)", row)
        self.assertIn('Text("next")', row)
        for marker in ("Theme.butter", "Theme.Size.currentTaskRadius.value", 'PerchPill("Now"', "steps()"):
            self.assertIn(marker, block)
        for source in (row, block):
            self.assertNotRegex(source, r"\.font\(\.system|Color\(hex:|\.animation\(")

    def test_live_draft_and_native_text_undo_keep_separate_ownership(self):
        source = (WORKSPACE / "TasksCard.swift").read_text()
        for marker in ('placeholder: "Add a task. Tab makes it a step."',
                       'AddField("Add a task"', 'homeState?.captureDraft = TodayHomeState.CaptureDraft',
                       'draft.startAt', 'draft.minutes ?? store.prefs.defaultFocusMinutes',
                       'CaptureTextUndo(onTab: changeIndent)', 'return capture.outdent()',
                       'return capture.indent(parentID: parent?.id)', 'editor.hasMarkedText()',
                       'field.currentEditor() === editor', 'manager.undo()', 'manager.redo()'):
            self.assertIn(marker, source)
        self.assertIn('.onDisappear { homeState?.captureDraft = nil }', source)
        self.assertNotIn('ViewThatFits', source)

    def test_native_keyboard_probe_covers_new_gestures_and_persistence(self):
        source = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        for marker in ('func verifyChecklistKeys(', 'await verifyChecklistKeys(',
                       'Right then Space completes the selected step', 'Option-Up persists personal order',
                       'Return publishes the selected editing identity', 'Command-K parks only the selected task',
                       'Undo restores the parked task and order atomically',
                       'typing publishes a timed preview to Your day',
                       'Tab then Return creates a step of the task above',
                       'Shift-Tab restores ordinary task entry', 'isFieldEditor',
                       'NSAttributedString', 'field.isEditable', 'button.title'):
            self.assertIn(marker, source)

    def test_every_added_state_has_a_real_snapshot_target(self):
        shots = (ROOT / "scripts/redesign_shots.list").read_text()
        registry = (ROOT / "Sources/PerchApp/App/AppDelegate+Preview.swift").read_text()
        for state in ("expanded", "steps", "selected", "step-entry", "completed"):
            target = "checklist-" + state
            self.assertIn(f'"{target}":', registry)
            self.assertIn("--open " + target, shots)
        for name in ("checklist-folded", "checklist-draft", "checklist-paused"):
            self.assertRegex(shots, re.compile(r"^" + name + " ", re.M))


    def test_step_cursor_is_invalidated_on_task_selection_and_step_removal(self):
        source = (WORKSPACE / "TasksCard.swift").read_text()
        changed = source.split('.onChange(of: homeState.selectedTaskID)', 1)[1].split('GeometryReader', 1)[0]
        self.assertIn('selectedStepID = nil', changed)
        self.assertIn('.onChange(of: selectedSteps)', source)
        self.assertIn('!remaining.contains(selectedStepID)', source)

    def test_stopwatch_never_borrows_the_tasks_estimate_for_an_end_time(self):
        source = (WORKSPACE / "CurrentTaskBlock.swift").read_text()
        self.assertIn('$0.taskID == task.id', source)
        self.assertIn('if let focus { duration = focus.limit }', source)
        self.assertNotIn('focus?.limit ?? task.minutes', source)


if __name__ == "__main__":
    unittest.main()
