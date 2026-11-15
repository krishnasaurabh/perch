"""The same native segment must own keyboard and accessibility focus."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
PROBE = ROOT / "Tests/PerchAppTests/SegmentedKeyboardTests.swift"
COMPONENT = ROOT / "Sources/PerchApp/Workspace/Components/PerchSegmented.swift"


class SegmentedKeyboardOwnershipTests(unittest.TestCase):
    def test_first_tab_requires_the_native_segment_in_the_active_fixture(self):
        source = PROBE.read_text()
        run = source.split("func run() async throws {", 1)[1]
        run = run.split("private func testArrowsAndEnds()", 1)[0]
        ordered = ('try assertEditor(driver.before)',
                   r'try await key(code: 48, characters: "\t")',
                   'traceFocus("First Tab keyboard ownership")',
                   'let responder = window.firstResponder as? NSView',
                   'window.isKeyWindow && responder?.window === window',
                   'responder is PerchSegmentKeyView',
                   'try assertSelectedAndFocused(45)', 'try await testArrowsAndEnds()')
        for step in ordered:
            self.assertIn(step, run)
        positions = [run.index(step) for step in ordered]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn('SwiftUI.KeyViewProxy', run)
        assertion = source.split("private func assertSelectedAndFocused(", 1)[1]
        assertion = assertion.split("private func accessibilityNodes(", 1)[0]
        self.assertNotIn("SwiftUI.KeyViewProxy", assertion)
        component = COMPONENT.read_text()
        setter = component.split("override func setAccessibilityFocused(", 1)[1].split("override func accessibilityPerformPress", 1)[0]
        self.assertNotIn("press()", setter)
        self.assertIn("window?.makeFirstResponder(self)", setter)
        self.assertIn("ForEach(items, id: \.value)", component)
        self.assertIn("PerchSegmentGroupView: NSView", component)
        self.assertIn("setAccessibilityRole(.group)", component)
        self.assertIn("view.setAccessibilityChildren(items.compactMap", component)
        self.assertIn("segment.frame = frames[item.value]", component)
        self.assertIn(".anchorPreference(key: PerchSegmentBounds<Value>.self", component)
        self.assertIn("driver.minutes == minutes", assertion)
        self.assertLess(assertion.index("traceFocus("), assertion.index("try require("))

    def test_segment_retains_keyboard_focus_without_semantic_focus_override(self):
        source = COMPONENT.read_text()
        for removed in ("@AccessibilityFocusState", ".accessibilityFocused(", "@FocusState"):
            self.assertNotIn(removed, source)
        for retained in ("PerchSegmentKeyView: NSControl", "setAccessibilityRole(.button)",
                         "override var acceptsFirstResponder: Bool { active && selectionEnabled() && focusEligible() }",
                         "window?.firstResponder === self", "window.makeFirstResponder(view)",
                         "override func isAccessibilitySelected() -> Bool { selected() }",
                         "override func isAccessibilityFocused() -> Bool", "window?.isKeyWindow == true"):
            self.assertIn(retained, source)

    def test_custom_duration_has_a_fallback_target_not_a_synthetic_selection(self):
        source = COMPONENT.read_text()
        target = source.split("private var tabTarget: Value? {", 1)[1].split("func update(", 1)[0]
        self.assertIn("if let selection, items.contains(selection) { return selection }", target)
        self.assertIn("return items.first", target)
        registration = source.split("func register(", 1)[1].split("private var tabTarget:", 1)[0]
        self.assertIn("view.selected = { [weak self] in self?.selection == value }", registration)
        self.assertIn("view.focusEligible = { [weak self] in self?.tabTarget == value }", registration)
        focus_entry = source.split("override func becomeFirstResponder()", 1)[1].split("override func resignFirstResponder()", 1)[0]
        self.assertNotIn("press()", focus_entry)
        self.assertNotIn("change(", focus_entry)
        self.assertIn('selected() ? "Selected" : "Not selected"', source)

    def test_native_general_duration_regression_reloads_and_navigates_the_real_control(self):
        source = PROBE.read_text()
        self.assertIn("@testable import PlannerCore", source)
        fixture = source.split("private struct GeneralLengthKeyboardFixture:", 1)[1].split("/// Drive", 1)[0]
        self.assertIn("SettingsGeneralPane.defaultLengthControl(store: store)", fixture)
        general = (ROOT / "Sources/PerchApp/Settings/SettingsGeneralPane.swift").read_text()
        self.assertIn("Self.defaultLengthControl(store: store)", general)
        run = source.split("private func testReloadedCustomDurations()", 1)[1].split("private func assertGeneralLength(", 1)[0]
        for token in ("for custom in [30, 50]", "try file.save(planner)",
                      "let store = PlannerStore(file: file, watching: false)",
                      "try connectKeyLoop(in: host)", "window.makeFirstResponder(driver.before)",
                      r'try await key(code: 48, characters: "\t")',
                      "focused: 15", "try Data(contentsOf: file.url) == saved",
                      'try await key(code: 49, characters: " ")',
                      r'try await key(code: 124, characters: "\u{f703}")',
                      "try assertEditor(driver.after)"):
            self.assertIn(token, run)
        assertion = source.split("private func assertGeneralLength(", 1)[1].split("private func connectKeyLoop(", 1)[0]
        for token in ("store.prefs == expected", "reloaded.prefs == expected", "eligible.count == 1",
                      "window.firstResponder === node", '(value == expected.defaultFocusMinutes ? "Selected" : "Not selected")'):
            self.assertIn(token, assertion)

    def test_ax_focus_is_asserted_for_every_selected_and_departed_segment(self):
        source = PROBE.read_text()
        assertion = source.split("private func assertSelectedAndFocused(", 1)[1]
        assertion = assertion.split("private func accessibilityNodes(", 1)[0]
        self.assertIn('boolean(node, "isAccessibilityFocused") == (value == minutes)', assertion)
        cleared = source.split("private func assertNoSegmentFocus(", 1)[1]
        cleared = cleared.split("private func accessibilityNodes(", 1)[0]
        self.assertIn('boolean(node, "isAccessibilityFocused") == false', cleared)
        self.assertIn("controls.count == 4", cleared)
        self.assertIn("traceFocus(", cleared)
        for check in ("controls.count == 4", "for value in [15, 25, 45, 60]",
                      "matches.count == 1", 'attribute(node, "accessibilityValue") as? String',
                      '(value == minutes ? "Selected" : "Not selected")'):
            self.assertIn(check, assertion)


if __name__ == "__main__":
    unittest.main()
