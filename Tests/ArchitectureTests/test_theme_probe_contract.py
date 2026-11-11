"""Guard native focus identity and rendered chart measurement boundaries."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ThemeProbeContractTests(unittest.TestCase):
    def test_pill_style_owns_native_button_focus(self):
        source = (ROOT / 'Sources/PerchApp/Workspace/Components/ControlStyle.swift').read_text()
        self.assertIn('struct PillStyle: PrimitiveButtonStyle', source)
        self.assertIn('Button(configuration)', source)
        self.assertIn('.focused($focused)', source)
        self.assertNotIn('@Environment(\\.isFocused)', source)

    def test_gallery_checks_native_identity_not_requested_focus(self):
        source = (ROOT / 'scripts/theme_probe.swift').read_text()
        self.assertIn('accessibilityFocusedUIElement', source)
        self.assertIn('theme-continue', source)
        self.assertNotIn('var continueFocused', source)
        self.assertIn('focus-diagnostic', source)

    def test_gallery_separates_rendered_ring_from_keyboard_verification(self):
        source = (ROOT / 'scripts/theme_probe.swift').read_text()
        self.assertIn('ControlFocusRing(shape: Capsule(), focused: true)', source)
        self.assertIn('"focus_evidence"', source)
        self.assertIn('"rendered-ring"', source)
        self.assertIn('"keyboardActivation"', source)
        self.assertIn('"unverified-on-this-runner"', source)
        self.assertIn('"verified-in-process-Tab-Space"', source)
        self.assertIn('accessibilityPerformPress', source)
        self.assertIn('"AXButton"', source)
        self.assertIn('"Continue"', source)
        self.assertIn('"AX press invokes Continue exactly once"', source)
        self.assertNotIn('Continue owns focus before keyboard activation', source)
        self.assertNotIn('Space activates the focused button exactly once', source)
        self.assertNotIn('Tab focuses the native field after the page-picker group', source)

    def test_chart_samples_tokens_and_compositor(self):
        source = (ROOT / 'scripts/empty_states_probe.swift').read_text()
        self.assertIn('ThemeTokens.chartPlanned', source)
        self.assertIn('ThemeTokens.chartCompleted', source)
        self.assertIn('.background(Theme.lavender)', source)
        self.assertNotIn('.background(Color.white)', source)
        self.assertNotIn('NSColor(Theme.chartPlanned)', source)
        self.assertIn('/usr/sbin/screencapture', source)
        self.assertIn('plannedRun >= 3', source)
        self.assertIn('Completed grows after the chart appears', source)
        self.assertIn('Completed is visible in the early frame', source)
        self.assertIn('Completed bar is drawn once grown', source)


if __name__ == '__main__':
    unittest.main()
