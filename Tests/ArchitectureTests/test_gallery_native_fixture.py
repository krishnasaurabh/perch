"""Keep the gallery's native accessibility fixture initialized and fail-closed."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Tests/PerchAppTests/GalleryInteractionTests.swift"


class GalleryNativeFixtureTests(unittest.TestCase):
    def test_native_priming_precedes_swiftui_host_creation(self):
        source = SOURCE.read_text()
        self.assertLess(
            source.index("await primeAccessibility()"),
            source.index("rootView: GalleryPage(page: .motion)"),
        )

    def test_priming_uses_only_native_content_and_off_main_queries(self):
        source = SOURCE.read_text()
        primer = source.split("private func primeAccessibility()", 1)[1].split(
            "private func find(", 1
        )[0]
        self.assertIn("NSTextField(labelWithString:", primer)
        self.assertNotIn("NSHostingView", primer)
        self.assertIn("DispatchQueue.global().async", primer)
        self.assertIn("AXUIElementSetMessagingTimeout", primer)
        self.assertIn("kAXWindowsAttribute", primer)
        self.assertIn("kAXChildrenAttribute", primer)
        self.assertNotIn("kAXFocusedUIElementAttribute", primer)
        self.assertIn("continuation.resume()", primer)

    def test_missing_controls_still_fail_after_diagnostics(self):
        source = SOURCE.read_text()
        lookup = source.split("private func find(", 1)[1].split(
            "private func attribute(", 1
        )[0]
        self.assertLess(lookup.index("dumpAccessibility(in: window)"), lookup.index("XCTFail("))
        self.assertIn("throw GalleryInteractionError.missingElement", lookup)
        self.assertIn("ContinuousClock.now + .seconds(3)", lookup)
        self.assertNotIn("XCTSkip", source)

    def test_original_actions_and_visible_state_assertions_are_preserved(self):
        source = SOURCE.read_text()
        for action in ("Start it now", "Pause", "+5 min", "Back to 24:10", "15"):
            self.assertIn(f'press(try await find("{action}", role: "AXButton", in: window))', source)
        for state in (
            "Start", "30 minutes left of 45", "25 minutes left of 45",
            "15 minutes left of 15", "10:00 – 10:45 · 3 of 4 steps",
        ):
            self.assertIn(f'find("{state}",', source)
        self.assertIn('find("Complete Write the smoke tests", role: "AXCheckBox"', source)
        self.assertIn('find("Heads-up before a block ends", role: "AXCheckBox", value: 0', source)
        self.assertIn('NSSelectorFromString("accessibilityPerformPress")', source)
        self.assertIn("XCTAssertTrue(unsafeBitCast", source)


if __name__ == "__main__":
    unittest.main()
