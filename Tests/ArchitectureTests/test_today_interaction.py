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

    def test_row_actions_own_focus_and_space_activation(self):
        source = (WORKSPACE / "TaskRow.swift").read_text()
        action = source.split("private func action(", 1)[1].split("private var metadata:", 1)[0]
        self.assertIn(".buttonStyle(PillStyle())", action)
        self.assertIn(".focusable(true)", action)
        self.assertLess(action.index(".focusable(true)"), action.index(".focused(focusBinding"))
        self.assertIn(".onKeyPress(.space, phases: [.down, .repeat, .up])", action)
        self.assertIn("focusBinding.wrappedValue == .task(task.id, kind)", action)
        self.assertIn("press.modifiers.isEmpty", action)
        self.assertIn("if press.phase == .down { perform() }", action)
        self.assertIn("ControlFocusRing(", action)

    def test_undo_owns_focus_and_space_activation(self):
        source = (WORKSPACE / "TasksCard.swift").read_text()
        undo = source.split("private var footer: some View {", 1)[1].split("Spacer(minLength:", 1)[0]
        self.assertIn(".focusable(store.canUndo)", undo)
        self.assertLess(undo.index(".focusable(store.canUndo)"), undo.index(".focused($focus"))
        self.assertIn(".onKeyPress(.space, phases: [.down, .repeat, .up])", undo)
        self.assertIn("focus == .undo, store.canUndo, press.modifiers.isEmpty", undo)
        self.assertIn("if press.phase == .down { store.undo() }", undo)

    def test_explicit_capture_request_restarts_native_focus(self):
        source = (WORKSPACE / "TasksCard.swift").read_text()
        request = source.split(".task(id: model.captureFocusRequest)", 1)[1].split(".overlay(ControlFocusRing", 1)[0]
        self.assertIn("focusBinding.wrappedValue = nil", request)
        self.assertLess(request.index("focusBinding.wrappedValue = nil"), request.index("await Task.yield()"))
        self.assertLess(request.index("await Task.yield()"), request.index("focusBinding.wrappedValue = .capture"))
        self.assertIn("guard !Task.isCancelled", request)

    def test_capture_destination_is_not_overridden_by_row_recovery(self):
        source = (WORKSPACE / "TasksCard.swift").read_text()
        recovery = source.split(".onChange(of: ids)", 1)[1].split(".onKeyPress", 1)[0]
        self.assertIn("guard focus != .capture && focus != .undo", recovery)
        request = source.split(".task(id: model.captureFocusRequest)", 1)[1].split(".overlay(ControlFocusRing", 1)[0]
        self.assertIn("if focused { focusBinding.wrappedValue = nil }", request)

    def test_failed_keyboard_and_reopen_checks_preserve_diagnostics(self):
        source = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        tab = source.split("func focusByTab(", 1)[1].split("func verifyLastRowKeyboardUndo", 1)[0]
        for expected in ('"firstResponder"', '"focusedIdentifiers"', '"step"', '"target"',
                         '"tab-trace-\\(identifier).json"'):
            self.assertIn(expected, tab)
        compact = (ROOT / "scripts/compact_home_probe.swift").read_text()
        self.assertLess(compact.index('recordFocus(delegate:'), compact.index('"\\(scenario): capture editor is focused"'))

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

    def test_row_probe_matches_static_text_labels_or_values_not_action_labels(self):
        source = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        self.assertIn('attr(node, "accessibilityRole") as? String == "AXStaticText"', source)
        self.assertIn('attr(node, "accessibilityLabel") as? String == text', source)
        self.assertIn('attr(node, "accessibilityValue") as? String == text', source)
        self.assertIn('staticText(linked.title, in: rowRoot)', source)
        self.assertIn('staticText(task.title, in: rowRoot)', source)
        self.assertIn('static-text selector accepts a value-only title', source)
        self.assertIn('static-text selector accepts a labelled title', source)
        self.assertIn('static-text selector rejects an action with matching text', source)
        self.assertIn('static-text selector rejects different and missing text', source)

    def test_priority_probe_resolves_exact_static_text_not_label_only(self):
        source = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        probe = source.split("// Textual priorities and multiline titles", 1)[1].split(
            'require(store.lastError == nil', 1)[0]
        self.assertIn('for priority in [TaskPriority.high, .medium, .low]', probe)
        self.assertIn('staticText("\\(priority.rawValue.capitalized) priority", in: rowRoot) != nil', probe)
        self.assertNotIn('control("\\(priority.rawValue.capitalized) priority", in: rowRoot)', probe)
        self.assertIn('"\\(priority): priority is text, not color alone"', probe)
        self.assertIn('staticText(task.title, in: rowRoot)', probe)
        self.assertIn('"\\(priority): long title actually wraps"', probe)
        selector = source.split('func staticText(', 1)[1].split('final class StaticTextProbeElement', 1)[0]
        self.assertIn('isStaticText($0, matching: text)', selector)
        self.assertIn('matches.count == 1', selector)

    def test_standalone_row_explicitly_enables_accessibility(self):
        source = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        initial = source.split('let rowRoot = NSHostingView(', 1)[1].split('rowWindow.contentView', 1)[0]
        replacement = source.split('rowRoot.rootView =', 1)[1].split('await settle()', 1)[0]
        for fixture in (initial, replacement):
            self.assertIn('.environment(\\.accessibilityEnabled, true)', fixture)

    def test_row_probe_records_evidence_before_title_lookup(self):
        source = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        before_lookup = source.split('guard let title = staticText(linked.title, in: rowRoot)', 1)[0]
        self.assertIn('snapshot(rowRoot, "task-before-context-click", into: output)', before_lookup)
        self.assertIn('recordAccessibility(rowRoot, "task-before-context-click", into: output)', before_lookup)
        self.assertIn('recordAccessibility(rowRoot, "task-\\(priority.rawValue)-narrow", into: output)', source)
        self.assertIn('"accessibilityContents"', source)

    def test_last_row_focus_recovers_to_undo_not_the_text_editor(self):
        source = (WORKSPACE / "TasksCard.swift").read_text()
        row = (WORKSPACE / "TaskRow.swift").read_text()
        recovery = source.split(".onChange(of: ids)", 1)[1].split(".onKeyPress", 1)[0]
        self.assertIn("case undo", row)
        self.assertIn("?? (store.canUndo ? .undo : .capture)", recovery)
        self.assertIn(".focused($focus, equals: .undo)", source)
        self.assertIn("ControlFocusRing(shape: Capsule(), focused: focus == .undo)", source)
        panel = (ROOT / "Sources/PerchApp/Notch/NotchGeometry.swift").read_text()
        self.assertIn("!(firstResponder is NSTextView)", panel)

    def test_row_semantics_are_on_an_accessible_leaf_inside_the_group(self):
        source = (WORKSPACE / "TaskRow.swift").read_text()
        self.assertIn("private var accessibleTitle: some View {", source)
        title = source.split("private var accessibleTitle: some View {", 1)[1].split("private var completion:", 1)[0]
        self.assertIn("Text(task.title)", title)
        self.assertIn('accessibilityIdentifier("task-row-\\(task.id)")', title)
        self.assertIn(".accessibilityValue(accessibilitySummary)", title)
        self.assertIn(".accessibilityHint(", title)
        self.assertIn(".accessibilityActions {", title)
        self.assertIn(".accessibilityElement(children: .contain)", source)
        self.assertNotIn(".accessibilityElement(children: .ignore)", source)
        self.assertNotIn(".accessibilityElement(children: .combine)", source)

    def test_rows_expose_named_accessibility_actions_and_state(self):
        source = (WORKSPACE / "TaskRow.swift").read_text()
        row = source.split("private var accessibleTitle: some View {", 1)[1].split("private var completion:", 1)[0]
        for expected in ('accessibilityIdentifier("task-row-\\(task.id)")',
                         '.accessibilityLabel(task.title)', '.accessibilityValue(accessibilitySummary)',
                         '.accessibilityHint(', '.accessibilityActions {',
                         'Button(task.done ? "Reopen" : "Complete", action: toggle)',
                         'Button("Details") { model.detailsTaskID = task.id }',
                         'Button("Delete", role: .destructive, action: delete)',
                         'if canFocus { Button("Focus", action: startFocus) }'):
            self.assertIn(expected, row)
        self.assertIn('task.done || ticked ? "Completed" : "Not completed"', source)
        self.assertIn('priority.rawValue.capitalized', source)
        self.assertIn('private func startFocus()', source)

    def test_native_last_row_delete_undo_uses_notch_panel_keyboard(self):
        source = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        for expected in ('let panel = NotchPanel(', 'for completed in [false, true]',
                         '"task-delete-\\(only.id)"',
                         'key(" ", code: 49, in: panel)',
                         'modifiers: [.command]',
                         'sameTaskContent(store.planner.tasks, beforeDeletion)',
                         'sameTaskContent(try! store.file.load().tasks, beforeDeletion)',
                         'store.planner.tasks == afterUndo',
                         '"last-row removal focuses Undo"',
                         '"capture Command-Z preserves planner history"',
                         '"capture Command-Z undoes only draft text"',
                         'await verifyLastRowKeyboardUndo('):
            self.assertIn(expected, source)

    def test_capture_shortcuts_are_owned_by_the_actual_native_editor(self):
        source = (WORKSPACE / "TasksCard.swift").read_text()
        self.assertIn("CaptureTextUndo()", source)
        bridge = source.split("struct CaptureTextUndo:", 1)[1]
        for expected in ("editor.delegate as? NSTextField", "field.currentEditor() === editor",
                         "field.window === window", "bounds.intersects(",
                         "NSText.didBeginEditingNotification", "editor.allowsUndo = true",
                         "NSEvent.addLocalMonitorForEvents", "NSEvent.removeMonitor",
                         "manager.undo()", "manager.redo()", "event.isARepeat",
                         "flags == .command", "flags == [.command, .shift]"):
            self.assertIn(expected, bridge)
        self.assertNotIn("store.undo", bridge)
        self.assertNotIn("NSApp.mainMenu =", bridge)

    def test_capture_monitor_transfers_only_consumption_across_actor_check(self):
        source = (WORKSPACE / "TasksCard.swift").read_text()
        monitor = source.split("monitor = NSEvent.addLocalMonitorForEvents", 1)[1].split(
            "enableUndo()", 1)[0]
        self.assertIn("let consumed: Bool = MainActor.assumeIsolated", monitor)
        self.assertIn("guard let self else { return false }", monitor)
        self.assertIn("return self.handle(event) == nil", monitor)
        self.assertIn("return consumed ? nil : event", monitor)
        self.assertNotIn("Task {", monitor)
        self.assertNotIn("@unchecked Sendable", source)

    def test_capture_undo_probe_records_native_history_and_editor_identity(self):
        source = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        for expected in ('func recordTextUndo(', '"allowsUndo"', '"canUndo"', '"canRedo"',
                         '"registrationEnabled"', '"isCurrentEditor"', '"mainMenuPresent"',
                         'recordTextUndo(editor, in: panel, phase: "before-command-z"',
                         'recordTextUndo(editor, in: panel, phase: "after-command-z"',
                         '"capture edit registers native Undo"',
                         '"capture Command-Shift-Z restores only draft text"',
                         '"capture Undo keeps the current editor"'):
            self.assertIn(expected, source)

    def test_capture_undo_redo_submits_the_binding_not_stale_text(self):
        source = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        for expected in ('func verifyCaptureUndoSubmission(', 'await verifyCaptureUndoSubmission(',
                         '"empty text Undo never consumes planner history"',
                         '"text Redo never consumes planner history"',
                         '"capture submission uses the undone and redone binding"',
                         '"capture submission persists the exact draft"'):
            self.assertIn(expected, source)

    def test_capture_selection_replacement_uses_native_selection_and_queued_typing(self):
        source = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        probe = source.split("func verifyCaptureUndoSubmission(", 1)[1].split(
            "func verifyRowCustomActions(", 1)[0]
        self.assertNotIn("editor.insertText(", probe)
        self.assertIn("await typeCaptureText(draft, in: panel)", probe)
        self.assertIn("await typeCaptureText(replacement, in: panel)", probe)
        self.assertIn("editor.setSelectedRange(selected)", probe)
        self.assertIn("editor.selectedRange() == selected", probe)
        self.assertIn('"capture receives the original draft through keyboard events"', probe)
        self.assertIn('"capture replaces exactly the selected draft"', probe)
        typing = source.split("func typeCaptureText(", 1)[1].split("// Edits, including Undo", 1)[0]
        self.assertIn("NSApp.postEvent(event, atStart: false)", typing)
        self.assertIn("NSEvent.EventType.keyDown, .keyUp", typing)
        self.assertNotIn("insertText", typing)
        self.assertNotIn("undoManager", typing)

    def test_capture_replacement_records_state_before_every_undo_assertion(self):
        source = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        probe = source.split("func verifyCaptureUndoSubmission(", 1)[1].split(
            "func verifyRowCustomActions(", 1)[0]
        for phase, assertion in (
            ("typed", "capture receives the original draft through keyboard events"),
            ("selected", "capture selects the entire original draft"),
            ("replaced", "capture replaces exactly the selected draft"),
            ("undo-replacement", "capture Undo restores the replaced selection"),
            ("redo-replacement", "capture Redo restores the replacement"),
            ("restored-draft", "capture returns to the draft before submission"),
        ):
            self.assertIn(f'phase: "{phase}"', probe)
            self.assertIn(f'"{assertion}"', probe)
            self.assertLess(probe.index(f'phase: "{phase}"'), probe.index(f'"{assertion}"'))
        record = source.split("func recordTextUndo(", 1)[1].split("func verifyLastRowKeyboardUndo(", 1)[0]
        self.assertIn('"selection": NSStringFromRange(editor.selectedRange())', record)
        self.assertIn('"hasMarkedText": editor.hasMarkedText()', record)
        self.assertIn('"currentEditorText":', record)

    def test_completed_keyboard_probe_reselects_restored_row_before_second_delete(self):
        source = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        probe = source.split("func verifyLastRowKeyboardUndo(", 1)[1].split(
            "func verifyRowCustomActions(", 1)[0]
        restored = probe.split('"last-row keyboard Undo persists exact task")', 1)[1].split(
            "let deleteAgain =", 1)[0]
        self.assertIn('if completed { press("Completed 1", in: root); await settle() }', restored)
        self.assertIn('control("task-delete-\\(only.id)", attribute: "accessibilityIdentifier", in: root)', restored)
        self.assertIn('"restored task Delete control is visible before keyboard traversal"', restored)
        self.assertIn('require(deleteAgain, "Tab reaches Delete again after Command-Z")', probe)
        self.assertIn('"second keyboard deletion removes the same task"', probe)
        self.assertIn('"Space activates visible Undo"', probe)
        self.assertIn('"Space Undo persists exact task"', probe)
        card = (WORKSPACE / "TasksCard.swift").read_text()
        self.assertIn("tab = TodayTabs.resolved(tab, completedCount: count)", card)

    def test_native_row_order_and_space_undo_remain_mandatory(self):
        source = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        for expected in ('let actionOrder = completed ? ["details", "delete"] : ["focus", "details", "delete"]',
                         '"Tab reaches row \\(action) in visible order"',
                         '"row Details keyboard action targets the exact task"',
                         '"Space activates visible Undo"',
                         '"Space Undo persists exact task"',
                         '"held Space does not consume another Undo"',
                         '"Space starts one focus session for the exact task"',
                         '"held Space does not start another focus session"'):
            self.assertIn(expected, source)
        compact = (ROOT / "scripts/compact_home_probe.swift").read_text()
        self.assertIn('"dense", "timer-notepad"', compact)
        self.assertIn('let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor', compact)

    def test_native_row_custom_actions_are_discovered_and_exercised(self):
        source = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        for expected in ('"accessibilityCustomActions"', '[NSAccessibilityCustomAction]',
                         'action.handler', 'action.selector', 'action.target',
                         'performCustomAction("Complete"', 'performCustomAction("Reopen"',
                         'performCustomAction("Details"', 'performCustomAction("Delete"',
                         'performCustomAction("Focus"',
                         '"row custom completion persists only the target"',
                         '"running row omits the Focus custom action"',
                         '"row custom deletion persists only the target"',
                         '"row custom reopening persists only the target"',
                         'await verifyRowCustomActions('):
            self.assertIn(expected, source)

    def test_overdue_policy_is_not_a_persistent_home_banner(self):
        source = "\n".join(p.read_text() for p in WORKSPACE.glob("*.swift"))
        self.assertNotIn("OverdueBanner()", source)
        self.assertNotIn('Picker(\n                "Overdue tasks"', source)
        self.assertIn('accessibilityIdentifier("today-review-overdue")', source)


if __name__ == "__main__":
    unittest.main()
