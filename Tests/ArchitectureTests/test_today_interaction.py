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

    def test_empty_state_probe_uses_stable_task_identifiers(self):
        source = (ROOT / "scripts/empty_states_probe.swift").read_text()
        self.assertIn('pressControl(completionID, attribute: "accessibilityIdentifier")', source)
        self.assertIn('let completionID = "task-complete-\\(id)"', source)
        self.assertIn('findControl(completionID, attribute: "accessibilityIdentifier")', source)
        self.assertIn('findControl("task-complete-\\($0)", attribute: "accessibilityIdentifier")', source)
        for label in ("Reopen Capture probe task", "Complete Capture probe task"):
            self.assertIn(f'findControl("{label}")', source)
        self.assertIn('delegate.store.planner.tasks.first { $0.id == id }?.done == false', source)
        for stale in ('"Check off task"', '"Uncheck task"'):
            self.assertNotIn(stale, source)

    def test_motion_probe_and_qualifiers_agree_on_identifiers(self):
        driver = (ROOT / "Sources/PerchApp/App/MotionScript.swift").read_text()
        negative = (ROOT / "scripts/check_motion_driver.sh").read_text()
        rules = (ROOT / "scripts/motion_evidence_rules.py").read_text()
        self.assertIn('self.requiredPress("task-complete-\\(task.id)", byIdentifier: true)', driver)
        self.assertIn('object(o, "accessibilityIdentifier")', driver)
        for source in (negative, rules):
            self.assertIn("ax-press:task-complete-", source)
            self.assertNotIn("ax-press:Check off task", source)
        self.assertIn("FAILED:missing-control:Start focus", negative)
        self.assertIn("['settled_state']['timer_present'] is False", negative)
        self.assertIn("['settled_state']['completed_target'] is True", negative)
        self.assertIn("tick-not-observed", rules)
        self.assertIn("missing-real-control", rules)

    def test_motion_tick_requires_a_real_press_and_observed_completion(self):
        import runpy
        qualify = runpy.run_path(str(ROOT / "scripts/motion_evidence_rules.py"))["qualify"]
        task_id = "11111111-1111-1111-1111-111111111111"
        marker = {
            "name": "tick", "via": f"ax-press:task-complete-{task_id}", "interaction_ok": True,
            "task_id": task_id,
            "policy": dict(nsworkspace_reduce_motion=False, swiftui_reduce_motion=False,
                           resolved_reduce_motion=False, explicit_reduce_motion=False, mode="production"),
            "session": dict(screen_locked=False, session_available=True, on_console=True, completed_tasks=0),
            "settled_state": dict(completed_tasks=1, completed_target=True),
        }
        self.assertTrue(qualify(marker, "a" * 40)["qualified"])
        other_task_id = "22222222-2222-2222-2222-222222222222"
        for via in ("ax-press:Check off task", "direct:complete", f"FAILED:missing-control:task-complete-{task_id}",
                    f"ax-press:task-complete-{other_task_id}"):
            result = qualify(dict(marker, via=via), "a" * 40)
            self.assertFalse(result["qualified"])
            self.assertIn("missing-real-control", result["reasons"])
        for invalid in (None, "", "not-a-task-id", 42):
            result = qualify(dict(marker, task_id=invalid), "a" * 40)
            self.assertFalse(result["qualified"])
            self.assertIn("missing-real-control", result["reasons"])
        result = qualify(dict(marker, settled_state=dict(completed_tasks=0, completed_target=True)), "a" * 40)
        self.assertFalse(result["qualified"])
        self.assertIn("tick-not-observed", result["reasons"])
        result = qualify(dict(marker, settled_state=dict(completed_tasks=1, completed_target=False)), "a" * 40)
        self.assertFalse(result["qualified"])
        self.assertIn("tick-target-not-observed", result["reasons"])

    def test_keyboard_probe_reads_native_boolean_focus(self):
        source = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        self.assertNotIn('attr(focus, "accessibilityFocused")', source)
        self.assertNotIn('attr(first, "accessibilityFocused")', source)
        self.assertIn('NSSelectorFromString("isAccessibilityFocused")', source)
        self.assertIn('@convention(c) (AnyObject, Selector) -> Bool', source)
        self.assertIn('isFocused(FocusProbeElement(true))', source)
        self.assertIn('!isFocused(FocusProbeElement(false))', source)
        self.assertIn('isFocused(first)', source)
        self.assertIn('isFocused(next)', source)
        self.assertIn('"task-complete-\\(added[0].id)"', source)
        self.assertIn('"task-complete-\\(added[2].id)"', source)
        self.assertIn('require(rowKeyboardReached,', source)
        self.assertIn('"keyboard-trace-\\(name).json"', source)

    def test_completion_space_is_focus_scoped_and_activates_once(self):
        source = (WORKSPACE / "TaskRow.swift").read_text()
        completion = source.split("private var completion: some View {", 1)[1].split(
            "private var actions: some View {", 1)[0]
        self.assertIn("Button(action: toggle)", completion)
        self.assertIn(".onKeyPress(.space, phases: [.down, .repeat, .up])", completion)
        self.assertIn("focusBinding.wrappedValue == .task(task.id, .complete)", completion)
        self.assertIn("press.modifiers.isEmpty", completion)
        self.assertIn("if press.phase == .down { toggle() }", completion)
        self.assertIn("return .handled", completion)
        self.assertIn("return .ignored", completion)

    def test_native_space_checks_exact_set_and_persisted_state(self):
        source = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        self.assertIn("let completedBeforeSpace =", source)
        self.assertIn("completedBeforeSpace.union([added[0].id])", source)
        self.assertIn("let persistedAfterSpace = try! store.file.load()", source)
        self.assertIn("persistedAfterSpace.tasks.filter(\\.done)", source)
        self.assertIn('recordKeyboardState("before-space")', source)
        self.assertIn('recordKeyboardState("after-space")', source)
        self.assertIn("isARepeat: isARepeat", source)
        self.assertIn("keyDown - no repeated completion", source)
        self.assertIn("Space reopens exactly the focused completed task", source)

    def test_keyboard_probe_mode_is_process_local(self):
        wrapper = (ROOT / "scripts/check_focus_entry.sh").read_text()
        source = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        self.assertIn("[binary, '-AppleKeyboardUIMode', '3']", wrapper)
        self.assertNotIn("defaults write", wrapper)
        self.assertIn('UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") == 3', source)

    def test_focus_probe_preserves_persisted_start_and_deletion_assertions(self):
        wrapper = (ROOT / "scripts/check_focus_entry.sh").read_text()
        source = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        self.assertIn('Data(contentsOf: store.file.url)', source)
        self.assertIn('output.appendingPathComponent("linked-focus.json")', source)
        self.assertIn("root / 'linked-focus.json'", wrapper)
        self.assertIn("saved['focus']['state'] == 'running'", wrapper)
        self.assertIn("final['focus']['state'] != 'running'", wrapper)
        self.assertIn("final['tasks'][0]['id'] == saved['tasks'][0]['id']", wrapper)

    def test_context_menu_probe_delivers_the_native_pointer_event(self):
        source = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        self.assertNotIn(".menu(for:", source)
        self.assertIn("rowWindow.sendEvent(contextEvent)", source)
        self.assertIn("rowWindow.convertPoint(fromScreen:", source)
        self.assertIn("NSMenu.didBeginTrackingNotification", source)
        self.assertIn("forMode: .eventTracking", source)
        self.assertIn("menu.cancelTracking()", source)
        self.assertIn('output.appendingPathComponent("context-menu-trace.json")', source)

    def test_context_menu_probe_keeps_real_action_and_exact_task_assertions(self):
        source = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        self.assertIn('require(taskMenu != nil, "existing task context menu exposes Start focusing")', source)
        self.assertIn('require(menu.items[index].isEnabled, "existing task menu item enabled")', source)
        self.assertEqual(source.count("menu.performActionForItem(at: index)"), 1)
        self.assertLess(source.index("menu.performActionForItem(at: index)"), source.index("menu.cancelTracking()"))
        self.assertIn("guard matchedMenu == nil else { return }", source)
        self.assertIn("store.planner.focus?.state == .running", source)
        self.assertIn("store.planner.focus?.taskID == linked.id && store.planner.focus?.limit == 720", source)
        self.assertIn("store.planner.tasks[0].id == linked.id", source)
        self.assertIn("store.planner.tasks[0].minutes == 12", source)
        self.assertIn('"taskActivation": "window-right-click-tracked-NSMenu-item-action"', source)
        wrapper = (ROOT / "scripts/check_focus_entry.sh").read_text()
        self.assertIn("result['taskActivation'] == 'window-right-click-tracked-NSMenu-item-action'", wrapper)

    def test_overdue_policy_is_not_a_persistent_home_banner(self):
        source = "\n".join(p.read_text() for p in WORKSPACE.glob("*.swift"))
        self.assertNotIn("OverdueBanner()", source)
        self.assertNotIn('Picker(\n                "Overdue tasks"', source)
        self.assertIn('accessibilityIdentifier("today-review-overdue")', source)


if __name__ == "__main__":
    unittest.main()
