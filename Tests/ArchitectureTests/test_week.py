"""Week controls must use calendar boundaries and preserve visible task text."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class WeekViewTests(unittest.TestCase):
    def test_week_is_not_a_rolling_eight_column_list(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WeekPage.swift").read_text()
        self.assertIn("WeekColumnLayout.days", source)
        self.assertIn('AppL10n.text("Back to week")', source)
        self.assertIn('AppL10n.format("Inbox (%lld)"', source)
        legacy = source.split('struct LegacyWeekPage: View {', 1)[1]
        calendar = legacy.split('ScrollView(.horizontal)', 1)[1].split('private func label', 1)[0]
        self.assertNotIn('column(title: "Inbox"', calendar)

    def test_selected_calendar_range_refreshes_on_date_changes(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WeekPage.swift").read_text()
        self.assertIn(".onChange(of: days, initial: true)", source)
        self.assertRegex(source, r"onChange\(of: days, initial: true\)\s*\{\s*_, value in\s*store.materializeRepeats\(on: value\)")
        navigation = source.split("private func go", 1)[1].split("func column", 1)[0]
        self.assertNotIn("materializeRepeats", navigation)

    def test_completion_buttons_name_their_tasks(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WeekPage.swift").read_text()
        self.assertIn('AppL10n.format("Uncheck task: %@", task.title)', source)
        self.assertIn('AppL10n.format("Check off task: %@", task.title)', source)

    def test_native_probe_imports_the_fixture_storage_module(self):
        source = (ROOT / "scripts/week_shots.sh").read_text()
        launcher = source.split("<<'SWIFT'", 1)[1].split("\nSWIFT", 1)[0]
        self.assertIn("try file.save(seed)", launcher)
        self.assertIn("@testable import PlannerCore", launcher)
        self.assertIn("-Xswiftc -enable-testing", source)

    def test_native_probe_publishes_and_walks_accessibility(self):
        source = (ROOT / "scripts/week_shots.sh").read_text()
        self.assertEqual(source.count(r'.environment(\.accessibilityEnabled, true)'), 2)
        self.assertIn('attribute(node, "accessibilityContents")', source)
        self.assertIn('(node as? NSView)?.subviews', source)
        self.assertIn('"AXButton", "Completion control is not a button"', source)
        self.assertIn('"Checking one task changed its neighbour"', source)

    def test_native_probe_reports_labeled_unwrap_failures_and_progress(self):
        source = (ROOT / "scripts/week_shots.sh").read_text()
        launcher = source.split("<<'SWIFT'", 1)[1].split("\nSWIFT", 1)[0]
        self.assertIn('XCTFreeUnwrap<T>(_ value: T?, _ label: String)', launcher)
        self.assertIn('NSLocalizedDescriptionKey: "Missing \\(label)"', launcher)
        for label in ["daily recurrence fixture", "editable rollover occurrence", "multiline fixture",
                      "persisted checked task", "tracked Week context menu", "enabled Details item"]:
            self.assertIn('"' + label + '"', launcher)
        self.assertIn('FileHandle.standardError.write', launcher)
        self.assertNotIn('print("PASS Week', launcher)
        self.assertNotIn('fputs(', launcher)

    def test_native_menu_probe_dispatches_to_rendered_title_and_tracks_appkit(self):
        source = (ROOT / "scripts/week_shots.sh").read_text()
        self.assertNotIn('.menu(for:', source)
        self.assertIn('NSMenu.didBeginTrackingNotification', source)
        self.assertIn('forMode: .eventTracking', source)
        self.assertIn('selector: #selector(tick)', source)
        self.assertIn('window.sendEvent(event)', source)
        self.assertIn('frame("title:\\(tasks[0].id)", in: host)', source)
        self.assertIn('menu.items[$0].isEnabled', source)
        self.assertIn('menu.performActionForItem(at: detailsIndex)', source)
        self.assertIn('model.detailsTaskID == tasks[0].id', source)
        self.assertIn('candidate.cancelTracking()', source)

    def test_multiline_fixture_is_checked_before_native_build(self):
        source = (ROOT / "scripts/week_shots.sh").read_text()
        self.assertIn('"literal": True', source)
        self.assertIn('assert len(multiline) == 1', source)
        self.assertIn('"multiline fixture missing or split"', source)

    def test_board_splits_native_typechecking_and_routes_shortcuts_by_row(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WeekPage.swift").read_text()
        board = source.split('private struct WeekBoardDay:', 1)[0]
        self.assertIn('private func dayColumn(', board)
        self.assertIn('private func scrollingBoard(', board)
        row = source.split('private struct WeekBoardTask:', 1)[1].split('struct WeekParkingColumn:', 1)[0]
        self.assertIn('.onKeyPress(.rightArrow, phases: .down)', row)
        self.assertIn('id: task.id', row.split('.onKeyPress(.rightArrow, phases: .down)', 1)[1])
        self.assertIn('WeekTaskPolicy.moveDestinations(', row)
        self.assertIn('displayedDays: days', row)
        self.assertNotIn('WeekColumnLayout.days(', row)

    def test_arrow_handlers_use_the_event_receiving_keypress_overload(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WeekPage.swift").read_text()
        handlers = re.findall(r'\.onKeyPress\((\.(?:leftArrow|rightArrow))([^)]*)\)\s*\{\s*key in', source)
        self.assertEqual([key for key, _ in handlers], ['.leftArrow', '.rightArrow', '.rightArrow'])
        for key, arguments in handlers:
            with self.subTest(key=key):
                self.assertEqual(arguments, ', phases: .down',
                                 "Single-key handlers receiving KeyPress need the phases overload")

    def test_native_keyboard_fixture_restores_task_only_before_neighbor_check(self):
        source = (ROOT / "Tests/PerchAppTests/WeekInboxKeyboardTests.swift").read_text()
        board = source.split('private static func redesignedBoard(', 1)[1].split(
            'private static func tabTo(', 1)[0]
        reset = 'store.send(.move(task.id, .day(future)))'
        self.assertEqual(board.count(reset), 1, "A second same-day reset fails before Space/Add coverage")
        self.assertLess(board.index(reset), board.index('let neighbor ='))
        for assertion in [
            'Option-Right from a checkbox pushes that exact row',
            'Option-Right from a checkbox does not push the previously focused menu row',
            'Space checks a future task and persists the change',
            'Space reopens the same future task',
            'Return in the coming-day field adds a task on that day',
        ]:
            self.assertIn(assertion, board)

    def test_week_footer_buttons_register_native_tab_stops(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WeekPage.swift").read_text()
        for identifier in ['week-overflow-', 'week-add-']:
            with self.subTest(identifier=identifier):
                before_identifier = source.split('.accessibilityIdentifier("' + identifier + r'\(day.raw)")', 1)[0]
                button = before_identifier.rsplit('Button(', 1)[1]
                self.assertIn('.focusable()', button)
                self.assertLess(button.index('.focusable()'), button.index('.focused($footerFocused)'))
                self.assertIn('.focusEffectDisabled()', button)
                self.assertIn('.frame(minHeight: Theme.Size.minimumTarget.value)', button)
                self.assertIn('FocusRing(shape: Capsule(), focused: footerFocused, surface: surface)', button)

    def test_week_tab_failure_reports_focused_identifiers_and_responder(self):
        source = (ROOT / "Tests/PerchAppTests/WeekInboxKeyboardTests.swift").read_text()
        helper = source.split('private static func tabTo(', 1)[1].split(
            'private static func activateKeyWindow(', 1)[0]
        self.assertIn('var visited = Set<String>()', helper)
        self.assertIn('for _ in 0..<100', helper)
        self.assertIn('boolean($0, "isAccessibilityFocused") == true', helper)
        self.assertIn('visited.formUnion(focused.compactMap { string($0, "accessibilityIdentifier") })', helper)
        self.assertIn('visited.sorted()', helper)
        self.assertIn('window.firstResponder', helper)
        self.assertIn('type(of:', helper)
        self.assertIn('try fail("Tab never reached', helper)

    def test_week_shortcuts_read_live_focus_and_preserve_fallback_guards(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WeekPage.swift").read_text()
        board, rest = source.split('private struct WeekBoardDay:', 1)
        day, rest = rest.split('private struct WeekBoardTask:', 1)
        row = rest.split('struct WeekParkingColumn:', 1)[0]
        self.assertNotIn('@State private var selectedTask', board)
        self.assertIn('@FocusedValue(\\.weekKeyboardFocus)', board)
        self.assertIn('.focusedValue(\\.weekKeyboardFocus, .day(day))', board)
        self.assertIn('.focusedValue(\\.weekKeyboardFocus, .other)', day)
        self.assertIn('.focusedValue(\\.weekKeyboardFocus, .task(task.id))', row)
        self.assertIn('guard keyboardFocus == .task(task.id)', row)
        fallback = board.split('private func pushSelected(', 1)[1]
        self.assertIn('guard day >= store.today', fallback)
        self.assertIn('focus: keyboardFocus', fallback)
        self.assertIn('store.planner.tasks.first(where: { $0.id == id })?.day == day', fallback)
        self.assertIn('return pushSelected(from: day) ? .handled : .ignored', board)

    def test_week_space_uses_live_checkbox_focus_without_activating_menus(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WeekPage.swift").read_text()
        board, rest = source.split('private struct WeekBoardDay:', 1)
        row = rest.split('private struct WeekBoardTask:', 1)[1].split('struct WeekParkingColumn:', 1)[0]
        checkbox = row.split('PerchCheckbox(', 1)[1].split('if past {', 1)[0]
        self.assertIn('.focusedValue(\\.weekKeyboardFocus, .checkbox(task.id))', checkbox)
        self.assertIn('.onKeyPress(.space, phases: [.down, .repeat, .up])', board)
        self.assertIn('guard key.modifiers.isEmpty', board)
        self.assertIn('if key.phase == .down', board)
        self.assertIn('WeekTaskPolicy.completionAction(', board)
        self.assertIn('focus: keyboardFocus, from: day, tasks: store.planner.tasks', board)
        self.assertNotIn('NSApp.currentEvent', board)

    def test_legacy_chip_completion_and_copy_allow_scheduled_days(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WeekPage.swift").read_text()
        chip = source.split('struct WeekChip: View {', 1)[1].split('final class WeekMenuKeyboardTarget', 1)[0]
        self.assertIn('WeekTaskPolicy.scheduledCompletionAction(for: task, today: store.today)', chip)
        self.assertIn('task.day.map { $0 < store.today } ?? false', chip)
        self.assertIn('Schedule this task before checking it.', chip)
        self.assertNotIn('Move this task to today before checking it.', chip)
        self.assertNotIn('Only today’s tasks can be checked', source)

    def test_chips_have_real_completion_and_menu_controls(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WeekPage.swift").read_text()
        self.assertIn("WeekTaskPolicy.scheduledCompletionAction", source)
        self.assertIn(".contextMenu", source)
        self.assertIn(".accessibilityIdentifier(\"week-check-", source)
        board, legacy = source.split('struct LegacyWeekPage: View {', 1)
        self.assertIn(".lineLimit(2)", board)
        self.assertNotIn(".lineLimit(2)", legacy)
        self.assertIn(".fixedSize(horizontal: false, vertical: true)", source)
        self.assertIn('WeekColumnLayout.columns', board)
        self.assertIn('TaskDragItem.self', board)
        self.assertIn('.onDrop(of: [.perchTask, .perchParkedThought]', board)
        self.assertEqual(board.count('.onDrop('), 1)
        self.assertIn('WeekTaskPolicy.scheduledCompletionAction', board)
        self.assertIn('ParkedThoughtDragItem.self', board)
        self.assertIn('WeekParkingColumn(days: days)', board)
        self.assertIn('key.modifiers == .option', board)


if __name__ == "__main__":
    unittest.main()
