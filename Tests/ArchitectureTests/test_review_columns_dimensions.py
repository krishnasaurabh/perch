"""Keep the portable Double token boundary explicit in the native column layout.

This is a source contract, not a SwiftUI compilation or geometry test.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReviewColumnsDimensionsTests(unittest.TestCase):
    def test_proposed_width_coalesces_with_a_nonoptional_cgfloat_token(self):
        source = (ROOT / "Sources/PerchApp/Settings/YourWeekView.swift").read_text()
        layout = source.split("struct ReviewColumns: Layout {", 1)[1]
        measure = layout.split("func sizeThatFits(", 1)[1].split("func placeSubviews(", 1)[0]
        # On Darwin CGFloat and Double are distinct. Do not let optional
        # promotion during ?? inference carry a CGFloat? into the cache.
        self.assertRegex(
            measure,
            re.compile(
                r"let\s+width\s*:\s*CGFloat\s*=\s*proposal\.width\s*\?\?\s*"
                r"CGFloat\(Theme\.Size\.todayWidth\.value\)"
            ),
        )
        self.assertIn("cache.width = width", measure)
        self.assertIn("return CGSize(width: width, height: height)", measure)
        self.assertNotIn("proposal.width!", measure)


if __name__ == "__main__":
    unittest.main()
