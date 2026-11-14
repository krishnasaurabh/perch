"""Pin native Tab exit to group departure, not a representable field editor."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
PROBE = ROOT / "Tests/PerchAppTests/SegmentedKeyboardTests.swift"


def body(source, name):
    section = source.split(f"private func {name}(", 1)[1]
    return section.split("\n        private func", 1)[0]


class SegmentedKeyboardExitTests(unittest.TestCase):
    def test_tab_and_back_tab_assert_group_departure_before_reentry(self):
        scenario = body(PROBE.read_text(), "testExitAndCancellation")
        ordered = (
            r'try send(code: 124, characters: "\u{f703}")',
            r'try send(code: 48, characters: "\t")',
            'await settle()',
            'try assertFocusLeftSegmentGroup("Tab must leave the segmented group")',
            'try assertFocusLeftSegmentGroup("Departed segments must release native focus")',
            'try require(driver.minutes == 45, "The arrow before Tab still selects 45")',
            r'try await key(code: 48, characters: "\u{19}", modifiers: .shift)',
            'try assertSelectedAndFocused(45)',
            r'try send(code: 123, characters: "\u{f702}")',
            r'try send(code: 48, characters: "\u{19}", modifiers: .shift)',
            'await settle()',
            'try assertFocusLeftSegmentGroup("Back-tab must leave the segmented group")',
            'try assertFocusLeftSegmentGroup("Departed segments must release native focus")',
            'driver.minutes = 60',
            'await settle()',
            'try require(window.makeFirstResponder(driver.before), "Return to the native destination before the final Tab")',
            'try assertEditor(driver.before)',
            r'try await key(code: 48, characters: "\t")',
            'try assertSelectedAndFocused(60)',
        )
        remaining = ''.join(scenario.split())
        for step in ordered:
            normalized = ''.join(step.split())
            self.assertIn(normalized, remaining)
            remaining = remaining.split(normalized, 1)[1]
        self.assertNotIn('assertEditor(driver.after)', scenario)
        self.assertEqual(scenario.count('assertEditor(driver.before)'), 1)
        self.assertEqual(scenario.count('assertFocusLeftSegmentGroup('), 4)

    def test_group_departure_walks_the_entire_native_responder_ancestry(self):
        assertion = body(PROBE.read_text(), "assertFocusLeftSegmentGroup")
        ordered = (
            'traceFocus(context)',
            'var responder = window.firstResponder as? NSView',
            'var responderChain: [String] = []',
            'while let view = responder',
            'responderChain.append(String(reflecting: type(of: view)))',
            'responder = view.superview',
            'responderChain=',
            'for typeName in responderChain',
            'try require(',
            'typeName != "SwiftUI.KeyViewProxy"',
            '!typeName.contains("PerchSegmentFocusAnchorView")',
            'context)',
        )
        remaining = ''.join(assertion.split())
        for step in ordered:
            normalized = ''.join(step.split())
            self.assertIn(normalized, remaining)
            remaining = remaining.split(normalized, 1)[1]
        self.assertEqual(assertion.count('traceFocus('), 1)
        self.assertNotIn('makeFirstResponder', assertion)
        self.assertNotIn('send(', assertion)

    def test_external_selection_retains_the_explicit_native_editor_assertion(self):
        scenario = body(PROBE.read_text(), "testExternalSelection")
        ordered = (
            'window.makeFirstResponder(driver.before)',
            'driver.minutes = 25',
            'try assertEditor(driver.before)',
            'try assertFocusLeftSegmentGroup("Departed segments must release native focus")',
        )
        positions = [scenario.index(step) for step in ordered]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(scenario.count('assertFocusLeftSegmentGroup('), 1)

    def test_disabled_inactive_and_reinserted_groups_use_native_departure(self):
        source = PROBE.read_text()
        scenario = body(source, "testDisabledAndInactive")
        ordered = (
            'driver.enabled = false',
            'driver.minutes = 25',
            'await settle()',
            'try require(window.makeFirstResponder(driver.before), "Move out of the disabled group")',
            'try assertFocusLeftSegmentGroup("Disabled segments must release native focus")',
            'driver.enabled = true',
            'try assertEditor(driver.before)',
            'try assertSelectedAndFocused(25)',
            'try require(other.isKeyWindow, "A stale restore must not activate its old window")',
            'try require(field.currentEditor() === other.firstResponder, "Preserve the other window\'s editor")',
            'try assertFocusLeftSegmentGroup("Inactive segments must release native focus")',
            'try assertSelectedAndFocused(60)',
            'driver.visible = false',
            'try require(window.makeFirstResponder(driver.before), "Leave the removed group")',
            'driver.visible = true',
            'try assertEditor(driver.before)',
            'try assertFocusLeftSegmentGroup("Reinserted segments must not reclaim native focus")',
        )
        remaining = ''.join(scenario.split())
        for step in ordered:
            normalized = ''.join(step.split())
            self.assertIn(normalized, remaining)
            remaining = remaining.split(normalized, 1)[1]
        self.assertEqual(scenario.count('assertFocusLeftSegmentGroup('), 3)
        self.assertEqual(source.count('try assertFocusLeftSegmentGroup('), 8)


if __name__ == "__main__":
    unittest.main()
