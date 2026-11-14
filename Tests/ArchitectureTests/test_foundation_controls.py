"""Foundation controls use tokens, preserve native actions and isolate motion."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
COMPONENTS = ROOT / "Sources/PerchApp/Workspace/Components"
FILES = ("PerchButton.swift", "PerchCheckbox.swift", "PerchSwitch.swift",
         "PerchSegmented.swift", "FocusRing.swift", "GlassButton.swift",
         "ControlStyle.swift", "SegmentPills.swift")


def literal_violations(source):
    # Ignore comments, but not code hidden on a line with an end-of-line comment.
    code = re.sub(r"/\*.*?\*/|//[^\n]*", "", source, flags=re.S)
    patterns = (
        r"\b0x[0-9a-fA-F]+\b", r'#[0-9a-fA-F]{6}\b',
        r"\bColor\s*\(\s*(?:red:|\.sRGB|hex:)",
        r"\b(?:width|height|minWidth|minHeight|maxWidth|maxHeight|radius|cornerRadius|lineWidth|duration|response|size|spacing)\s*:\s*\d",
        r"\.padding\([^\n)]*,\s*\d", r"\.padding\(\s*\d",
        r"\.font\(\.system", r"\bColor\.(?:black|white|red|green|blue|gray)\b",
    )
    return [match.group() for pattern in patterns for match in re.finditer(pattern, code)]


class FoundationControlTests(unittest.TestCase):
    def test_components_have_no_literal_colors_dimensions_or_timings(self):
        for name in FILES:
            with self.subTest(name=name):
                self.assertEqual(literal_violations((COMPONENTS / name).read_text()), [])

    def test_literal_guard_rejects_each_family(self):
        for bad in ('Color(hex: "#F0714F")', 'Color.white',
                    '.frame(width: 20)', '.padding(.horizontal, 18)',
                    '.animation(.easeOut(duration: 0.12))', '.font(.system(size: 14))'):
            with self.subTest(bad=bad):
                self.assertTrue(literal_violations(bad))

    def test_all_new_controls_keep_keyboard_focus_and_reduce_motion(self):
        for name in FILES[:4]:
            source = (COMPONENTS / name).read_text()
            with self.subTest(name=name):
                if name == 'PerchSegmented.swift':
                    self.assertIn('window.makeFirstResponder(view)', source)
                    self.assertIn('focusRingType = .none', source)
                else:
                    self.assertIn('.focused(', source)
                    self.assertIn('.focusEffectDisabled()', source)
                self.assertIn('FocusRing(', source)
                self.assertNotIn('ViewThatFits', source)
                self.assertNotIn('.id(', source)
        shared = (COMPONENTS / 'PerchButton.swift').read_text()
        self.assertIn('policy.reduceMotion', shared)
        self.assertIn('DesignTokens.Motion.pressScale', shared)
        self.assertIn('DesignTokens.Size.hoverLift.value', shared)
        self.assertIn('.designMotion(.press', shared)
        self.assertIn('.designMotion(.hover', shared)

    def test_focus_is_keyboard_only_and_outside_layout(self):
        source = (COMPONENTS / 'FocusRing.swift').read_text()
        for token in ('keyboard', '.leftMouseDown', '.keyDown', 'focusGap',
                      'focusWidth', '.inset(by:', '.allowsHitTesting(false)'):
            self.assertIn(token, source)
        self.assertIn('focused && modality.keyboard', source)

    def test_checkbox_draw_and_pop_and_native_toggle_semantics(self):
        source = (COMPONENTS / 'PerchCheckbox.swift').read_text()
        for token in ('Complete %@', 'title', '.accessibilityRepresentation', 'Toggle(',
                      '.tickFill', '.tickDraw', 'tickScale', '.trim(', '.keyframeAnimator'):
            self.assertIn(token, source)

    def test_switch_has_native_value_and_token_slide(self):
        source = (COMPONENTS / 'PerchSwitch.swift').read_text()
        for token in ('.accessibilityRepresentation', 'Toggle(', '.designMotion(.pop',
                      '.switchKnob', '.switchWidth', '.switchHeight'):
            self.assertIn(token, source)

    def test_segment_group_has_value_selected_trait_and_roving_keyboard(self):
        source = (COMPONENTS / 'PerchSegmented.swift').read_text()
        for token in ('setAccessibilityValue(', 'isAccessibilitySelected()', 'case 123:', 'case 124:',
                      'case 115:', 'case 119:', 'matchedGeometryEffect', '.designMotion(.pop',
                      '.layoutDirection', 'acceptsFirstResponder: Bool { active && selectionEnabled() && selected() }'):
            self.assertIn(token, source)

    def test_legacy_apis_are_retained_and_deprecated(self):
        for name in FILES[5:]:
            source = (COMPONENTS / name).read_text()
            self.assertIn('@available(*, deprecated', source)


if __name__ == '__main__':
    unittest.main()
