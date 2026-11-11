"""Week controls must use calendar boundaries and preserve visible task text."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class WeekViewTests(unittest.TestCase):
    def test_week_is_not_a_rolling_eight_column_list(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WeekPage.swift").read_text()
        self.assertIn("WeekColumnLayout.days", source)
        self.assertIn('Button(showInbox ? "Back to week"', source)
        calendar = source.split('ScrollView(.horizontal)', 1)[1].split('private func label', 1)[0]
        self.assertNotIn('column(title: "Inbox"', calendar)

    def test_selected_calendar_range_refreshes_on_date_changes(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WeekPage.swift").read_text()
        self.assertIn(".onChange(of: days, initial: true)", source)
        self.assertRegex(source, r"onChange\(of: days, initial: true\)\s*\{\s*_, value in\s*store.materializeRepeats\(on: value\)")
        navigation = source.split("private func go", 1)[1].split("func column", 1)[0]
        self.assertNotIn("materializeRepeats", navigation)

    def test_completion_buttons_name_their_tasks(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WeekPage.swift").read_text()
        self.assertIn('help: task.done ? "Uncheck task: \\(task.title)" : "Check off task: \\(task.title)"', source)

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

    def test_chips_have_real_completion_and_menu_controls(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WeekPage.swift").read_text()
        self.assertIn("WeekTaskPolicy.completionAction", source)
        self.assertIn(".contextMenu", source)
        self.assertIn(".accessibilityIdentifier(\"week-check-", source)
        self.assertNotIn(".lineLimit(2)", source)
        self.assertIn(".fixedSize(horizontal: false, vertical: true)", source)


if __name__ == "__main__":
    unittest.main()
