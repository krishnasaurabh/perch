"""The guidance fixture must lay out its real host before reading native controls."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Tests/PerchAppTests/AgentGuidanceLifetimeTests.swift"


class AgentGuidanceHostTests(unittest.TestCase):
    def test_host_uses_explicit_size_and_activation_before_ax_queries(self):
        source = SOURCE.read_text()
        fixture = source.split("private final class AgentGuidanceFixture:", 1)[1]
        setup = fixture.split("func readStatus", 1)[0]
        self.assertLess(setup.index("NSApp.setActivationPolicy(.accessory)"),
                        setup.index("let host = NSHostingView("))
        self.assertIn("window.setContentSize(SettingsMetrics.windowSize)", setup)
        self.assertIn("NSApp.activate(ignoringOtherApps: true)", setup)
        self.assertLess(setup.index("window.setContentSize("),
                        setup.index("window.makeKeyAndOrderFront(nil)"))

    def test_each_native_inventory_flushes_layout_without_relaxing_lookup(self):
        source = SOURCE.read_text()
        inventory = source.split("private func nodes(in window: NSWindow)", 1)[1]
        self.assertLess(inventory.index("window.contentView?.layoutSubtreeIfNeeded()"),
                        inventory.index("var result:"))
        # Retain the original acceptance boundaries and real public AX action.
        self.assertIn("ContinuousClock.now + .seconds(3)", source)
        self.assertRegex(source, re.escape('identifier($0) == id && attribute($0, "accessibilityRole") as? String == "AXButton"'))
        self.assertIn('XCTAssertEqual(controls.count, 1,', source)
        self.assertIn('NSSelectorFromString("accessibilityPerformPress")', source)
        self.assertIn('XCTAssertTrue(unsafeBitCast(implementation, to: Press.self)(control, selector))', source)
        self.assertIn("diagnostics(in: window)", source)


if __name__ == "__main__":
    unittest.main()
