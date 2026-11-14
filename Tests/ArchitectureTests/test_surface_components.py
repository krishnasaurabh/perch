"""Keep surface primitives token-driven and their interaction semantics explicit."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
COMPONENTS = ROOT / "Sources/PerchApp/Workspace/Components"
FILES = ("CardSurface.swift", "CardHeading.swift", "StatusLabel.swift",
         "DotGridSheet.swift", "AddField.swift", "PerchPill.swift")


def literal_violations(source):
    source = re.sub(r'//[^\n]*|/\*.*?\*/', '', source, flags=re.S)
    source = re.sub(r'"(?:\\.|[^"\\])*"', '""', source)
    # Origins/empty spacing and halving a dimension into a radius are geometry,
    # not independently authored visual values.
    source = re.sub(r'/\s*2\b', '', source)
    failures = re.findall(r'(?<![\w.])(?:[1-9]\d*(?:\.\d+)?|0\.\d+)\b', source)
    failures += re.findall(r'\bColor\s*\(|\.shadow\s*\(|\.systemFont\s*\(', source)
    failures += re.findall(r'\.(?:red|green|blue|white|black|gray|orange|yellow|purple)\b', source)
    return failures


class SurfaceComponentArchitectureTests(unittest.TestCase):
    def test_all_owned_components_exist_and_have_no_visual_literals(self):
        for name in FILES:
            with self.subTest(file=name):
                self.assertEqual(literal_violations((COMPONENTS / name).read_text()), [])

    def test_guard_rejects_independent_geometry_color_font_and_duration(self):
        for source in ('Text("x").padding(16)', '.frame(height: 44)',
                       'let radius: CGFloat = 20', '.font(.system(size: 13))',
                       '.animation(.easeOut(duration: 0.16))', 'Color(red: 0, green: 0, blue: 0)',
                       '.foregroundStyle(.red)', '.shadow(radius: 0)'):
            with self.subTest(source=source):
                self.assertTrue(literal_violations(source))
        self.assertEqual(literal_violations('size.width / 2; CGPoint.zero; spacing: 0'), [])

    def test_sheet_grid_is_noninteractive_and_clips_panel_corners(self):
        source = (COMPONENTS / 'DotGridSheet.swift').read_text()
        for token in ('dotDiameter', 'dotSpacing', 'sheetPadding', 'windowPadding', 'sheetBottomRadius'):
            self.assertIn(token, source)
        for behavior in ('Canvas', '.allowsHitTesting(false)', '.accessibilityHidden(true)',
                         'UnevenRoundedRectangle', 'bottomLeadingRadius:', 'bottomTrailingRadius:'):
            self.assertIn(behavior, source)

    def test_new_card_path_does_not_force_an_appearance(self):
        source = (COMPONENTS / 'CardSurface.swift').read_text().split('struct Card<', 1)[1]
        for token in ('cardRadius', 'cardPadding', 'cardEdge', 'currentTaskRadius'):
            self.assertIn(token, source)
        self.assertIn('Theme.edge(surface)', source)
        self.assertIn('Theme.fill(surface)', source)
        self.assertNotIn('\.colorScheme', source)
        self.assertNotIn('.shadow', source)

    def test_pills_are_display_content_not_controls(self):
        source = (COMPONENTS / 'PerchPill.swift').read_text()
        for forbidden in ('Button(', '.onTapGesture', '.onHover', '.focusable', '.frame(height:'):
            self.assertNotIn(forbidden, source)
        for required in ('Capsule()', 'pillMinHeight', 'pillMaxHeight', '.perchFont(', 'minHeight:'):
            self.assertIn(required, source)

    def test_add_field_has_real_label_submit_and_separate_dictation(self):
        source = (COMPONENTS / 'AddField.swift').read_text()
        for required in ('TextField(', 'Text(AppL10n.text(label))', '.labelsHidden()',
                         '.accessibilityLabel(Text(AppL10n.text(label)))',
                         'AppL10n.text("Dictate instead")', '.onSubmit(onSubmit)', 'Button(action: onDictate)',
                         '.focused(', 'fieldFocusWidth', 'focusWidth', 'focusGap', '.paper', '.field',
                         'minimumTarget', 'addFieldHeight', 'addFieldRadius'):
            self.assertIn(required, source)
        self.assertNotIn('ViewThatFits', source)
        self.assertNotIn('.id(', source)
        self.assertNotIn('.animation(', source)

    def test_capture_fixture_preserves_semantics_with_typed_lookup(self):
        source = (ROOT / 'Tests/PerchAppTests/SurfaceComponentTests.swift').read_text()
        for required in ('compactMap { $0 as? NSTextField }', '.filter(\\.isEditable)',
                         'accessibilityIdentifier() == "capture-add-task"',
                         'accessibilityLabel() == "Add a task"',
                         'placeholderString == "Add a task. Tab makes it a step."',
                         'NSAttributedString', 'attributed.string', 'layoutSubtreeIfNeeded()',
                         'Surface capture inventory:', 'window.makeFirstResponder(entry)',
                         '"accessibilityRole") as? String, "AXTextField"',
                         '"accessibilityLabel") as? String, "Add a task"'):
            self.assertIn(required, source)
        self.assertNotIn('if window.firstResponder is NSTextView { break }', source)
        self.assertIn('"capture-add-task"', (COMPONENTS / 'AddField.swift').read_text())


if __name__ == '__main__':
    unittest.main()
