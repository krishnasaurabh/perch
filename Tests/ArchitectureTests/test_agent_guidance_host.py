"""Keep guidance checks on the registered, out-of-process native Settings host."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Tests/PerchAppTests/AgentGuidanceLifetimeTests.swift"
SUPPORT = ROOT / "Tests/PerchAppTests/AgentGuidanceProbeSupport.swift"


class AgentGuidanceHostTests(unittest.TestCase):
    def test_host_uses_explicit_size_and_activation_before_ax_queries(self):
        source = SOURCE.read_text()
        support = SUPPORT.read_text()
        host = (ROOT / "Sources/PerchApp/App/WindowHost.swift").read_text()
        pane = (ROOT / "Sources/PerchApp/Settings/SettingsAgentsPane.swift").read_text()
        self.assertIn("#if AGENT_GUIDANCE_PROBE", source)
        self.assertIn("app.setActivationPolicy(.regular)", source)
        self.assertIn("app.run()", source)
        self.assertIn('AppDelegate.previewTarget("settings/agents-connected")', support)
        self.assertIn("target.open(delegate)", support)
        self.assertIn("target.surface(delegate)", support)
        self.assertIn('size: SettingsMetrics.windowSize', pane)
        self.assertLess(host.index("contentRect: NSRect(origin: .zero, size: size)"),
                        host.rindex("w.makeKeyAndOrderFront(nil)"))
        self.assertIn("NSApp.activate(ignoringOtherApps: true)", host)
        self.assertNotIn("NSHostingView", support)
        self.assertIn("await primeAccessibility()", source)
        self.assertIn("AXUIElementCopyAttributeValue", source)

    def test_each_native_inventory_flushes_layout_without_relaxing_lookup(self):
        source = SOURCE.read_text()
        inventory = source.split("private func nodes(in window: NSWindow)", 1)[1]
        self.assertLess(inventory.index("window.contentView?.layoutSubtreeIfNeeded()"),
                        inventory.index("var result:"))
        self.assertIn("ContinuousClock.now + .seconds(3)", source)
        self.assertRegex(source, re.escape('identifier($0) == id && attribute($0, "accessibilityRole") as? String == "AXButton"'))
        self.assertIn('try guidanceEqual(controls.count, 1,', source)
        self.assertIn('NSSelectorFromString("accessibilityPerformPress")', source)
        self.assertIn('try guidanceRequire(unsafeBitCast(implementation, to: Press.self)(control, selector))', source)
        wait = source.split("private func waitUntil", 1)[1].split("private func press", 1)[0]
        self.assertIn("diagnostics(in: window)", wait)
        self.assertIn('AppL10n.text("Not connected")', source)

    def test_parent_checks_each_original_scenario_once_and_child_exit(self):
        source = SOURCE.read_text()
        probe, parent = source.split("#else", 1)
        scenarios = (
            "testRetryGuidanceReachesTheRecreatedPaneForEveryApp",
            "testRetryWhileAwayPublishesGuidanceOnReturnWithoutLeakingToAnotherWindow",
        )
        for name in scenarios:
            self.assertIn(f"try await check.{name}()", probe)
            self.assertIn(f'print("PASS: {name}")', probe)
            self.assertIn(f"func {name}() throws", parent)
            self.assertIn(f'assertPass("PASS: {name}")', parent)
        self.assertIn("filter { $0 == marker }.count, 1", parent)
        self.assertIn("process.terminationReason == .exit, process.terminationStatus == 0", parent)
        self.assertIn("check=True, timeout=300", parent)
        self.assertIn("check=True, timeout=120", parent)
        self.assertNotIn("XCTSkip", source)
        self.assertIn("private static let result: Result<String, Error>", parent)

    def test_only_disposable_constructor_is_injected_and_state_is_window_local(self):
        source = SOURCE.read_text()
        support = SUPPORT.read_text()
        self.assertIn("assert source.count(old) == 1", source)
        self.assertIn("pane.write_text(source.replace(old, new, 1))", source)
        self.assertIn("temporary.appendingPathComponent", source)
        self.assertIn("fixtures[ObjectIdentifier(store)]", support)
        self.assertIn("statuses: statuses, feedback: feedback, readStatus: fixture.readStatus", support)
        self.assertIn("disconnect: fixture.disconnect, connect: fixture.connect", support)
        self.assertIn('WindowHost.windows.removeValue(forKey: "settings")', support)
        self.assertIn('guidanceNil(Bundle.main.bundleIdentifier)', support)
        self.assertIn("calendarStatus == .notDetermined || calendarStatus == .denied || calendarStatus == .restricted", support)
        self.assertIn("planner.preferences.catchCopies = false", support)
        self.assertIn("planner.preferences.catchScreenshots = false", support)


if __name__ == "__main__":
    unittest.main()
