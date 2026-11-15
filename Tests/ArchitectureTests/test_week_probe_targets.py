"""Contracts for isolated Week probe instrumentation, not native rendering claims."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
from scripts.week_measurement_hooks import instrument
from scripts.measure_capture_contrast import board_tokens
from scripts.theme_contrast import week_checkbox_boxes


class WeekProbeTargetTests(unittest.TestCase):
    def test_checkbox_target_rejects_missing_low_contrast_or_text_only_controls(self):
        class Pixels:
            def __init__(self, rows): self.rows = rows
            def __getitem__(self, point):
                x, y = point
                return self.rows[y][x]

        class Image:
            def __init__(self, rows):
                self.rows, self.width, self.height = rows, len(rows[0]), len(rows)
            def load(self): return Pixels(self.rows)

        for scheme in ('light', 'dark'):
            for scale in (1, 2):
                tokens = board_tokens(scheme)
                for state in ('valid', 'missing', 'text-only', 'low-contrast', 'wrong-size', 'filled'):
                    with self.subTest(scheme=scheme, scale=scale, state=state):
                        rows = [[tokens['butter']] * (868 * scale) for _ in range(70 * scale)]
                        if state == 'text-only':
                            for y in range(30*scale, 40*scale):
                                for x in range(40*scale, 48*scale): rows[y][x] = tokens['ink']
                        elif state != 'missing':
                            size = 26 if state == 'wrong-size' else 20
                            ink = tokens['butter'] if state == 'low-contrast' else tokens['ink']
                            for y in range(30*scale, (30+size)*scale):
                                for x in range(40*scale, (40+size)*scale):
                                    if (x < 42*scale or x >= (38+size)*scale
                                            or y < 32*scale or y >= (28+size)*scale):
                                        rows[y][x] = ink
                            if state == 'filled': rows[40*scale][50*scale] = tokens['ink']
                        if state == 'valid':
                            self.assertEqual(week_checkbox_boxes(Image(rows), tokens),
                                             [(40*scale, 30*scale, 60*scale, 50*scale)])
                        else:
                            with self.assertRaisesRegex(AssertionError, 'Missing production Week completion outlines'):
                                week_checkbox_boxes(Image(rows), tokens)

    def test_board_title_marker_measures_native_menu_not_its_detached_label(self):
        source = (ROOT / 'Sources/PerchApp/Workspace/WeekPage.swift').read_text()
        result = instrument(source)
        board, legacy = result.split('struct LegacyWeekPage: View {', 1)
        self.assertIn('.accessibilityIdentifier("week-menu-\\(task.id)")\n'
                      '                .background(WeekMeasure(key: "board-title:\\(task.id)"))', board)
        title = board.split('private var title: some View {', 1)[1].split('private var details:', 1)[0]
        self.assertNotIn('WeekMeasure', title)
        self.assertIn('.lineLimit(2).fixedSize(horizontal: false, vertical: true)', title)
        self.assertNotIn('board-title:', legacy)
        self.assertEqual(board.count('WeekMeasure(key: "board-title:'), 1)
        self.assertIn('WeekMeasure(key: "title:', legacy)

    def test_capture_instrumentation_is_library_scoped_and_requires_exact_footer_hook(self):
        wrapper = (ROOT / 'scripts/check_capture_contrast.sh').read_text()
        chunk = wrapper.split("<<'PY'\n", 1)[1].split('\nPY', 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / 'Sources/PerchApp/Workspace'
            workspace.mkdir(parents=True)
            (root / 'Sources/Perch').mkdir()
            week = workspace / 'WeekPage.swift'
            original = (ROOT / 'Sources/PerchApp/Workspace/WeekPage.swift').read_text()
            week.write_text(original)
            command = [sys.executable, '-', str(root), str(ROOT / 'scripts/capture_contrast_probe.swift')]
            result = subprocess.run(command, input=chunk, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            instrumented = week.read_text()
            self.assertEqual(instrumented.count('.background(WeekFooterMeasure(day: day.raw))'), 1)
            self.assertEqual(instrumented.replace('\n                            .background(WeekFooterMeasure(day: day.raw))', ''), original)
            helper = (workspace / 'WeekFooterMeasure.swift').read_text()
            entry = (root / 'Sources/Perch/main.swift').read_text()
            self.assertIn('enum WeekFooterMeasurements', helper)
            self.assertIn('import AppKit\nimport SwiftUI', helper)
            self.assertNotIn('enum WeekFooterMeasurements', entry)
            self.assertEqual(entry.count('try WeekFooterMeasurements.save('), 2)
            self.assertIn('--week-board --week-dark "$OUT/week" --week-light "$OUT/week-light"', wrapper)
            self.assertIn('timeout=60', wrapper)
            week.write_text(original.replace('week-add-\\(day.raw)', 'changed-footer-\\(day.raw)'))
            broken = subprocess.run(command, input=chunk, text=True, capture_output=True)
            self.assertNotEqual(broken.returncode, 0)
            self.assertIn('Week Add footer measurement hook changed', broken.stderr)


if __name__ == '__main__':
    unittest.main()
