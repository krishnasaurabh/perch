"""Synthetic fixtures for measure_capture_contrast.py: 1x and 2x snapshots must measure the same way."""
import struct
import tempfile
import unittest
import zlib
from pathlib import Path

from measure_capture_contrast import measure, over_black, ratio

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


if __name__ == "__main__":
    unittest.main()
