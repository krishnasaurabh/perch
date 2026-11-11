"""Synthetic fixtures for measure_capture_contrast.py: 1x and 2x snapshots must measure the same way."""
import struct
import tempfile
import unittest
import zlib
from pathlib import Path

from measure_capture_contrast import measure, measure_week, mini_fills, over_black, ratio

SHELL = (0, 0, 0)


def write_png(path, rows):
    raw = b"".join(b"\x00" + bytes(c for p in row for c in p) for row in rows)
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", len(rows[0]), len(rows), 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def field(scale, ink, fill=None):
    """Black shell with a 300x38 (1x) capture field: plus at x 10-20, prompt at 30-150, mic at 280-290."""
    fill = fill or over_black(0.08)
    w, h = 340 * scale, 60 * scale
    rows = [[SHELL] * w for _ in range(h)]
    fx0, fy0 = 20 * scale, 11 * scale
    for y in range(fy0, fy0 + 38 * scale):
        for x in range(fx0, fx0 + 300 * scale):
            rows[y][x] = fill
    # Fill-coloured specks in the shell corner (as the rounded shell edge produces at 2x) must not widen the field.
    for y in range(fy0, fy0 + 38 * scale, 3):
        rows[y][1] = fill
    for x0, x1 in ((10, 20), (30, 150), (280, 290)):
        for y in range(fy0 + 14 * scale, fy0 + 24 * scale):
            for x in range(fx0 + x0 * scale, fx0 + x1 * scale):
                rows[y][x] = ink
    return rows


class MeasureTests(unittest.TestCase):
    def measure(self, rows):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "notch-1-open.png"
            write_png(p, rows)
            return measure(p)

    def test_same_clusters_at_1x_and_2x(self):
        ink = (0x47, 0x53, 0x4A)
        one, two = self.measure(field(1, ink)), self.measure(field(2, ink))
        self.assertEqual((one["scale"], two["scale"]), (1, 2))
        for r in (one, two):
            self.assertEqual(r["field_state"], "resting")
            self.assertEqual(r["placeholder"]["ratio"], round(ratio(ink, over_black(0.08)), 3))
            self.assertLess(r["placeholder"]["ratio"], 4.5)
            self.assertEqual(r["plus"]["ratio"], r["placeholder"]["ratio"])
        self.assertEqual([x * 2 for x in one["placeholder"]["x"]], two["placeholder"]["x"])

    def test_dark_prompt_passes_on_focused_fill(self):
        r = self.measure(field(2, (0x1A, 0x1A, 0x1A), fill=over_black(0.12)))
        self.assertEqual(r["field_state"], "focused")
        self.assertGreaterEqual(r["placeholder"]["ratio"], 4.5)


def week(scale, ink):
    """Black shell, a #1D1D1D day tile holding a 70x22 (1x) MiniComposer field with an 8x20 prompt."""
    # The compositor renders the field as #292929, 1 above the 8-bit token math (#282828); the +/-2 match covers it.
    tile, fill = (0x1D,) * 3, (0x29,) * 3
    assert max(abs(a - b) for a, b in zip(fill, mini_fills()["tile"])) <= 2
    w, h = 120 * scale, 50 * scale
    rows: list[list[tuple[int, ...]]] = [[SHELL] * w for _ in range(h)]
    for y in range(5 * scale, 45 * scale):
        for x in range(10 * scale, 110 * scale):
            rows[y][x] = tile
    fx0, fy0 = 20 * scale, 20 * scale
    for y in range(fy0, fy0 + 22 * scale):
        for x in range(fx0, fx0 + 70 * scale):
            rows[y][x] = fill
    for y in range(fy0 + 7 * scale, fy0 + 15 * scale):
        for x in range(fx0 + 6 * scale, fx0 + 26 * scale):
            rows[y][x] = ink
    return rows


class WeekTests(unittest.TestCase):
    def measure(self, rows):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "notch-1-open.png"
            write_png(p, rows)
            return measure_week(p)

    def test_system_placeholder_grey_fails(self):
        # AppKit's placeholder grey as rendered on the dark tile before the fix (#858585 on #292929, 3.94:1).
        for scale in (1, 2):
            r = self.measure(week(scale, (0x85, 0x85, 0x85)))
            self.assertEqual(r["scale"], scale)
            self.assertEqual(len(r["fields"]), 1)
            self.assertEqual(r["fields"][0]["background_rgb"], "#292929")
            self.assertLess(r["fields"][0]["ratio"], 4.5)

    def test_background_scan_bridges_small_glyph_and_outline_gaps(self):
        for scale in (1, 2):
            for level in (0x85, 0xAE):
                with self.subTest(scale=scale, ink=level):
                    ink = (level, level, level)
                    rows: list[list[tuple[int, ...]]] = week(scale, ink)
                    for y in range(29 * scale, 31 * scale):
                        for x in range(20 * scale, 80 * scale):
                            rows[y][x] = ink
                    r = self.measure(rows)
                    self.assertEqual(r["scale"], scale)
                    self.assertEqual(r["fields"][0]["field_xyxy"][1::2], [20 * scale, 42 * scale])
                    measured = r["fields"][0]["ratio"]
                    self.assertEqual(measured, round(ratio(ink, (0x29,) * 3), 3))
                    self.assertEqual(measured >= 4.5, level == 0xAE)

    def test_shared_control_fill_and_single_visible_day(self):
        for scale in (1, 2):
            for level, passes in ((0x75, False), (0xF5, True)):
                with self.subTest(scale=scale, ink=level):
                    # One 70pt field in a 620pt page; a taller chip above shares its fill.
                    rows: list[list[tuple[int, ...]]] = [[SHELL] * (620 * scale) for _ in range(200 * scale)]
                    fill = mini_fills()["control"]
                    for top, bottom in ((10, 100), (150, 182)):
                        for y in range(top * scale, bottom * scale):
                            for x in range(20 * scale, 90 * scale):
                                rows[y][x] = fill
                    for y in range(160 * scale, 172 * scale):
                        for x in range(25 * scale, 70 * scale):
                            rows[y][x] = (level,) * 3
                    r = self.measure(rows)
                    self.assertEqual(r["scale"], scale)
                    self.assertEqual(len(r["fields"]), 1)
                    self.assertEqual(r["fields"][0]["field_xyxy"][1::2], [150 * scale, 182 * scale])
                    self.assertEqual(r["fields"][0]["ratio"] >= 4.5, passes)

    def test_footer_fill_coloured_pixels_do_not_hide_the_composers(self):
        for scale in (1, 2):
            for level, passes in ((0x75, False), (0xF5, True)):
                with self.subTest(scale=scale, ink=level):
                    fill = mini_fills()["control"]
                    rows: list[list[tuple[int, ...]]] = [[SHELL] * (620 * scale) for _ in range(240 * scale)]
                    for y in range(150 * scale, 182 * scale):
                        for x in range(20 * scale, 220 * scale):
                            rows[y][x] = fill
                    for y in range(160 * scale, 172 * scale):
                        for x in range(25 * scale, 100 * scale):
                            rows[y][x] = (level,) * 3
                    # Antialiased footer glyphs can match the dark control fill.
                    # Include a sustained run, not only isolated specks.
                    for y in range(215 * scale, 219 * scale):
                        for x in range(20 * scale, 120 * scale):
                            rows[y][x] = fill
                    measured = self.measure(rows)
                    self.assertEqual(measured["scale"], scale)
                    self.assertEqual(len(measured["fields"]), 1)
                    self.assertEqual(measured["fields"][0]["field_xyxy"],
                                     [20 * scale, 150 * scale, 220 * scale, 182 * scale])
                    self.assertEqual(measured["fields"][0]["ratio"] >= 4.5, passes)

    def test_missing_or_blank_composer_fails_closed(self):
        for scale in (1, 2):
            fill = mini_fills()["control"]
            rows: list[list[tuple[int, ...]]] = [[SHELL] * (320 * scale) for _ in range(100 * scale)]
            for y in range(80 * scale, 84 * scale):
                for x in range(20 * scale, 120 * scale):
                    rows[y][x] = fill
            with self.subTest(scale=scale, state="missing"):
                with self.assertRaisesRegex(AssertionError, "no Week composer"):
                    self.measure(rows)
            for y in range(20 * scale, 52 * scale):
                for x in range(20 * scale, 220 * scale):
                    rows[y][x] = fill
            with self.subTest(scale=scale, state="blank"):
                with self.assertRaisesRegex(AssertionError, "no prompt glyphs"):
                    self.measure(rows)

    def test_secondary_token_passes(self):
        # Theme.secondary dark (white 62 %) over the field.
        r = self.measure(week(2, (0xAE, 0xAE, 0xAE)))
        self.assertGreaterEqual(r["fields"][0]["ratio"], 4.5)


if __name__ == "__main__":
    unittest.main()
