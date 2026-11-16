"""Structural guards for the native dashboard keyboard regression tests.

These checks do not claim to execute AppKit. The interaction sequence remains in
integration_probe.swift and the native DashboardKeyLoopTests target.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources/PerchApp/Settings/DashboardView.swift"
NATIVE = ROOT / "Tests/PerchAppTests/DashboardKeyLoopTests.swift"


class DashboardKeyboardLifecycleTests(unittest.TestCase):
    def test_tab_entry_is_installed_before_conditional_history_search(self):
        source = SOURCE.read_text()
        install = source.split("static func install(in window: NSWindow)", 1)[1]
        self.assertLess(install.index("window.initialFirstResponder = tabs"),
                        install.index("searchIdentifier"))
        self.assertIn("root.nextKeyView = tabs", install)
        self.assertIn("host.selectionState?.tab == .history", install)

    def test_representable_updates_environment_not_host_root(self):
        source = SOURCE.read_text()
        update = source.split("func updateNSView(", 1)[1].split("func sizeThatFits", 1)[0]
        self.assertNotIn("rootView =", update)
        self.assertIn("updateEnvironment", update)
        self.assertIn("@ObservedObject var selection: DashboardSelection", source)
        self.assertIn(".onKeyPress(.tab, phases: .down) { press in", source)
        self.assertIn("didSet", source.split("final class DashboardSelection", 1)[1].split("private final", 1)[0])

    def test_native_regressions_cover_non_history_and_immediate_activation(self):
        tests = NATIVE.read_text()
        for name in ("testEverySectionInstallsInitialTabStopWithoutRequiringSearch",
                     "testArrowAndSpaceUseCurrentSelectionAndDoNotStealPageKeys",
                     "testSelectionChangesPreserveHostedRootAndRefreshHistoryLinks"):
            self.assertIn("func " + name, tests)
        self.assertIn("testHistorySearchHasExplicitTabPredecessor", tests)
        self.assertIn("testDetachedSearchDoesNotConsumeNavigationOrTextCommands", tests)


if __name__ == "__main__":
    unittest.main()
