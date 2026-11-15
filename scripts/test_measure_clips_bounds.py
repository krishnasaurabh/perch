import contextlib
from copy import deepcopy
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from PIL import Image, ImageDraw
from measure_clips_bounds import (FIXTURES, SHELF_KEYBOARD_ASSERTIONS, main, measure,
                                  validate_shelf_keyboard)


class ClipsBoundsTests(unittest.TestCase):
    def fixture(self, folder, scale=1, bleed=False, erase_slot=False, erase_title=False):
        records = []
        for appearance in ("dark", "light"):
            fill = (0x4A, 0x30, 0x1A) if appearance == "dark" else (0xFF, 0xC8, 0x9A)
            ink = (0xD2, 0xC4, 0xB7) if appearance == "dark" else (0x5E, 0x45, 0x3A)
            primary = (0xF6, 0xED, 0xE4) if appearance == "dark" else (0x2A, 0x1B, 0x14)
            for width in (400, 640):
                for state in ("empty", "one", "populated", "cleared"):
                    name = f"{appearance}-{width}-{state}.png"
                    im = Image.new("RGB", ((width + 48) * scale, 248 * scale))
                    draw = ImageDraw.Draw(im)
                    draw.rectangle((24 * scale, 24 * scale, (width + 24) * scale - 1, 224 * scale - 1), fill=fill)
                    if not erase_title:
                        draw.rectangle((44 * scale, 38 * scale, 200 * scale, 44 * scale), fill=primary)
                    slot = [width - 120, 110, width + 6, 194]
                    if not erase_slot:
                        # These synthetic strokes prove anchor/ink rejection, not native layout.
                        draw.rectangle(tuple(n * scale for n in slot), outline=ink, width=scale)
                    if bleed:
                        draw.point((10 * scale, 10 * scale), fill=ink)
                    im.save(folder / name)
                    records.append(dict(file=name, width=width + 48, height=248, stripWidth=width,
                                        appearance=appearance, state=state, card=[24, 24, width + 24, 224], slot=slot))
        (folder / "captures.json").write_text(json.dumps(records))

    def test_contained_at_one_and_two_times_scale(self):
        for scale in (1, 2):
            with tempfile.TemporaryDirectory() as d:
                folder = Path(d)
                self.fixture(folder, scale)
                rows = measure(folder)
                self.assertEqual(len(rows), 16)
                self.assertTrue(all(r["exterior_painted_pixels"] == 0 for r in rows))
                self.assertTrue(all(r["drop_slot_ink_pixels"] > 0 and r["title_ink_pixels"] > 0 for r in rows))

    def test_one_outside_pixel_is_not_ignored(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d)
            self.fixture(folder, bleed=True)
            self.assertTrue(all(r["exterior_painted_pixels"] == 1 for r in measure(folder)))

    def test_missing_slot_and_missing_header_are_red_at_both_scales(self):
        for scale in (1, 2):
            for flag, key in (("erase_slot", "drop_slot_ink_pixels"), ("erase_title", "title_ink_pixels")):
                with self.subTest(scale=scale, erased=flag), tempfile.TemporaryDirectory() as d:
                    folder = Path(d)
                    self.fixture(folder, scale, **{flag: True})
                    rows = measure(folder)
                    self.assertTrue(all(r[key] == 0 for r in rows))
                    output = io.StringIO()
                    with patch.object(sys, "argv", ["measure_clips_bounds.py", str(folder)]), contextlib.redirect_stdout(output):
                        self.assertTrue(main())
                    self.assertEqual(len(json.loads(output.getvalue())["failures"]), 16)

    def test_wrong_anchor_cannot_pass_a_real_drop_slot(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d)
            self.fixture(folder)
            records = json.loads((folder / "captures.json").read_text())
            for record in records:
                record["slot"] = [250, 150, 270, 170]
            (folder / "captures.json").write_text(json.dumps(records))
            self.assertTrue(all(r["drop_slot_ink_pixels"] == 0 for r in measure(folder)))

    def test_missing_duplicate_or_wrong_states_fail(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d)
            self.fixture(folder)
            records = json.loads((folder / "captures.json").read_text())
            for changed in ([], records[:-1], records[:-1] + [records[0]]):
                (folder / "captures.json").write_text(json.dumps(changed))
                with self.assertRaises(AssertionError):
                    measure(folder)

    def test_keyboard_manifest_retains_week_and_requires_all_shelf_actions(self):
        valid = {"surface": "drop-shelf", "runs": [{"broken": "", "red": "", "ok": True,
                 "passed": list(SHELF_KEYBOARD_ASSERTIONS + FIXTURES)}]}
        self.assertEqual(validate_shelf_keyboard(valid), 19)
        for label in SHELF_KEYBOARD_ASSERTIONS:
            changed = deepcopy(valid)
            changed["runs"][0]["passed"].remove(label)
            with self.assertRaises(ValueError):
                validate_shelf_keyboard(changed)
        for broken in (dict(broken="wrong", red="other", ok=True, passed=[]),
                       dict(broken=SHELF_KEYBOARD_ASSERTIONS[0], red="", ok=False, passed=[])):
            with self.assertRaises(ValueError):
                validate_shelf_keyboard(dict(valid, runs=valid["runs"] + [broken]))
        native = (Path(__file__).parent / "clips_layout_probe.swift").read_text()
        for label in SHELF_KEYBOARD_ASSERTIONS:
            self.assertIn(f'"{label}"', native)


if __name__ == "__main__":
    unittest.main()
