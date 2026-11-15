"""Portable replay of Settings probe logic, not native accessibility evidence."""
import shutil
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def function(source, name):
    match = re.search(rf"^@MainActor\s+func {name}\(", source, re.MULTILINE)
    assert match is not None, f"missing probe helper: {name}"
    following = re.search(r"^@MainActor\s+func ", source[match.end():], re.MULTILINE)
    assert following is not None
    return source[match.start():match.end() + following.start()]


class SettingsThemeNavigationTests(unittest.TestCase):
    def run_swift(self, program):
        swift = shutil.which("swiftc")
        assert swift is not None
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "settings-probe.swift"
            path.write_text(program)
            executable = path.with_suffix("")
            built = subprocess.run([swift, "-swift-version", "6", str(path), "-o", str(executable)],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stderr)
            ran = subprocess.run([str(executable)], capture_output=True, text=True, timeout=20)
            self.assertEqual(ran.returncode, 0, ran.stderr)
            return ran.stdout

    def test_arrow_steps_confirm_focus_and_bound_retries(self):
        source = (ROOT / "scripts/theme_probe.swift").read_text()
        helper = function(source, "advanceSettingsSidebar")
        self.assertIn("settingsSidebarFocused", helper)
        self.assertIn("50_000_000", helper)
        self.assertIn("systemUptime + 1", helper)
        self.assertNotIn("navigation.pane =", helper)
        program = r'''
import Foundation
class NSView {}
class NSWindow {}
enum SettingsView {
    enum Pane: String, CaseIterable {
        case general, notch, calendar, agents, data
        func next() -> Self {
            let index = Self.allCases.firstIndex(of: self)!
            return Self.allCases[min(index + 1, Self.allCases.count - 1)]
        }
    }
}
@MainActor class SettingsNavigation { var pane = SettingsView.Pane.general }
struct Modifiers: OptionSet {
    let rawValue: Int
    static let numericPad = Self(rawValue: 1)
    static let function = Self(rawValue: 2)
}
@MainActor enum Measured {
    static var failures: [String] = []
    static func check(_ ok: Bool, _ message: String) { if !ok { failures.append(message) } }
}
@MainActor enum Replay {
    static var navigation = SettingsNavigation()
    static var focused = SettingsView.Pane.general
    static var pending: SettingsView.Pane?
    static var polls = 0
    static var presses = 0
    static var mode = "immediate"
    static func reset(_ mode: String) {
        navigation = SettingsNavigation()
        focused = .general
        pending = nil
        polls = 0
        presses = 0
        self.mode = mode
        Measured.failures = []
    }
}
@MainActor func key(_ code: UInt16, _ character: String, in window: NSWindow, modifiers: Modifiers) {
    precondition(code == 125 && character == String(UnicodeScalar(0xF701)!))
    precondition(modifiers == [.numericPad, .function])
    Replay.presses += 1
    if Replay.mode == "lost" || (Replay.mode == "lost-first" && Replay.presses % 2 == 1) { return }
    precondition(Replay.pending == nil, "sent another arrow before the previous focus transfer")
    Replay.navigation.pane = Replay.focused.next()
    if Replay.mode == "selection-only" { return }
    if Replay.mode == "delayed" {
        Replay.pending = Replay.navigation.pane
        Replay.polls = 3
    } else {
        Replay.focused = Replay.navigation.pane
    }
}
@MainActor func settingsSidebarFocused(_ host: NSView, pane: SettingsView.Pane) -> Bool {
    if let pending = Replay.pending {
        Replay.polls -= 1
        if Replay.polls == 0 {
            Replay.focused = pending
            Replay.pending = nil
        }
    }
    return Replay.focused == pane
}
@MainActor func settingsFocusedIdentifier(_ host: NSView) -> String {
    "settings.sidebar.\(Replay.focused.rawValue)"
}
@MainActor func settle() async { await Task.yield() }
''' + helper + r'''
Task { @MainActor in
    let host = NSView(), window = NSWindow()
    for mode in ["immediate", "delayed", "lost-first"] {
        Replay.reset(mode)
        var arrowPresses = 0
        for pane in SettingsView.Pane.allCases.dropFirst() {
            let ok = await advanceSettingsSidebar(to: pane, host: host, window: window,
                                                  navigation: Replay.navigation, label: mode,
                                                  arrowPresses: &arrowPresses)
            precondition(ok, mode)
            precondition(Replay.focused == pane && Replay.navigation.pane == pane, mode)
            precondition(arrowPresses == Replay.presses, "count every actual arrow, including retries")
        }
        precondition(Replay.presses == (mode == "lost-first" ? 8 : 4), mode)
        precondition(Measured.failures.isEmpty, mode)
    }
    for mode in ["lost", "selection-only"] {
        Replay.reset(mode)
        let started = ProcessInfo.processInfo.systemUptime
        var arrowPresses = 0
        let ok = await advanceSettingsSidebar(to: .notch, host: host, window: window,
                                              navigation: Replay.navigation, label: mode,
                                              arrowPresses: &arrowPresses)
        precondition(!ok && Replay.presses == 2, "retry must be bounded and fail closed")
        precondition(arrowPresses == Replay.presses, "failed keys must also be counted")
        precondition(ProcessInfo.processInfo.systemUptime - started < 3)
        precondition(Measured.failures.count == 1)
        let failure = Measured.failures[0]
        precondition(failure.contains("notch -> \(Replay.navigation.pane.rawValue)"), failure)
        precondition(failure.contains("settings.sidebar.general"), failure)
    }
    print("Settings arrow replay passed")
    exit(0)
}
dispatchMain()
'''
        self.assertIn("Settings arrow replay passed", self.run_swift(program))

    def test_capture_identity_and_contrast_pair_use_observed_detail(self):
        source = (ROOT / "scripts/theme_probe.swift").read_text()
        helpers = function(source, "settingsRenderedPane") + function(source, "settingsContrastPairMatches")
        program = r'''
import Foundation
enum SettingsView { enum Pane: String { case general, notch, calendar, agents, data } }
class Node: NSObject {
    let identifier: String
    init(_ identifier: String) { self.identifier = identifier }
}
class NSView { var nodes: [NSObject] = [] }
@MainActor func pageNodes(_ host: NSView) -> [NSObject] { host.nodes }
@MainActor func controlAttribute(_ node: NSObject, _ name: String) -> Any? {
    precondition(name == "accessibilityIdentifier")
    return (node as? Node)?.identifier
}
''' + helpers + r'''
MainActor.assumeIsolated {
    let host = NSView()
    host.nodes = [Node("settings.detail.calendar"), Node("settings.detail.calendar"),
                  Node("settings.sidebar.notch"), Node("unrelated")]
    precondition(settingsRenderedPane(host) == .calendar)
    host.nodes.append(Node("settings.detail.notch"))
    precondition(settingsRenderedPane(host) == nil, "ambiguous detail must not be guessed")
    host.nodes = [Node("settings.sidebar.calendar"), Node("settings.detail.unknown")]
    precondition(settingsRenderedPane(host) == nil, "selected/sidebar identity is not rendered detail")
    host.nodes = []
    precondition(settingsRenderedPane(host) == nil)
    precondition(settingsContrastPairMatches(.calendar, .calendar))
    precondition(!settingsContrastPairMatches(.calendar, .notch))
    precondition(!settingsContrastPairMatches(nil, .calendar))
    precondition(!settingsContrastPairMatches(.calendar, nil))
    precondition(!settingsContrastPairMatches(nil, nil))
}
print("Settings capture identity replay passed")
'''
        self.assertIn("Settings capture identity replay passed", self.run_swift(program))

    def test_actual_ratio_comparison_skips_only_unmatched_settings_captures(self):
        source = (ROOT / "scripts/theme_probe.swift").read_text()
        comparison = source.split("// Increased contrast must never render less contrast", 1)[1]
        comparison = comparison.split("// Pages that render a StatusLabel", 1)[0]
        comparison = comparison[comparison.index("        if let standard"):].rsplit("    }", 1)[0]
        program = r'''
import Foundation
enum SettingsView { enum Pane: String { case calendar, notch } }
struct PageInk { let maxRatio: Double }
@MainActor enum Measured {
    static var results: [Bool] = []
    static func check(_ condition: Bool, _ message: String) { results.append(condition) }
}
''' + function(source, "settingsContrastPairMatches") + r'''
@MainActor func compare(_ standardPane: SettingsView.Pane?, _ increasedPane: SettingsView.Pane?,
                         ratio: Double, settings: Bool = true) -> [Bool] {
    Measured.results = []
    let page = (name: "fixture", settingsPane: settings ? SettingsView.Pane.calendar : nil)
    var renderedPanes: [String: SettingsView.Pane] = [:]
    renderedPanes["standard"] = standardPane
    renderedPanes["increased-contrast"] = increasedPane
    let ink = ["standard": PageInk(maxRatio: 19.343), "increased-contrast": PageInk(maxRatio: ratio)]
''' + comparison + r'''
    return Measured.results
}
MainActor.assumeIsolated {
    precondition(compare(.calendar, .calendar, ratio: 16.336) == [false])
    precondition(compare(.calendar, .calendar, ratio: 19.343) == [true])
    precondition(compare(.calendar, .notch, ratio: 16.336).isEmpty)
    precondition(compare(nil, .calendar, ratio: 16.336).isEmpty)
    precondition(compare(nil, nil, ratio: 16.336).isEmpty)
    precondition(compare(nil, nil, ratio: 16.336, settings: false) == [false])
}
print("Settings comparison replay passed")
'''
        output = self.run_swift(program)
        self.assertIn("Settings comparison replay passed", output)
        self.assertEqual(output.count("pair skipped, captures rendered different panes"), 3)

    def test_theme_calls_guarded_steps_and_preserves_measurement_gates(self):
        source = (ROOT / "scripts/theme_probe.swift").read_text()
        measured = source.split("@MainActor func measureEffectiveStates(", 1)[1]
        self.assertNotIn("for _ in 0..<index", measured)
        self.assertIn("for expectedPane in SettingsView.Pane.allCases.prefix(index + 1).dropFirst()", measured)
        self.assertIn("await advanceSettingsSidebar(", measured)
        self.assertIn("navigation.pane == pane && settingsSidebarFocused(host, pane: pane)", measured)
        self.assertIn("the Settings sidebar accepts native keyboard focus", measured)
        self.assertIn("let renderedPane = settingsRenderedPane(host)", measured)
        self.assertIn("renderedPane == pane", measured)
        self.assertIn('"rendered_settings_pane": renderedPane?.rawValue', measured)
        self.assertIn("settingsContrastPairMatches(", measured)
        self.assertIn("pair skipped, captures rendered different panes", measured)
        for gate in ("measured.inkPixels >= 150", "measured.maxRatio >= 4.5",
                     "frames.contains { content.intersects($0.1) }", "observation.typeSize == typeSize",
                     'observed == (state.increased ? "increased" : "standard")',
                     "increased.maxRatio + 0.01 >= standard.maxRatio", "big >= base * 1.4"):
            self.assertIn(gate, measured)

    def test_both_settings_focus_walkers_avoid_multiterm_typecheck(self):
        for name, helper_name, reader in (("theme_probe.swift", "settingsSidebarFocused", "controlAttribute"),
                                          ("integration_probe.swift", "matrixSettingsFocused", "value")):
            source = (ROOT / "scripts" / name).read_text()
            helper = function(source, helper_name)
            with self.subTest(name=name):
                self.assertIn("var children: [NSObject] = []", helper)
                last = -1
                for selector in ("accessibilityChildren", "accessibilityContents",
                                 "accessibilityChildrenInNavigationOrder"):
                    line = f'children += ({reader}(node, "{selector}") as? [NSObject]) ?? []'
                    position = helper.index(line)
                    self.assertGreater(position, last)
                    last = position
                self.assertIn("children += (node as? NSView)?.subviews ?? []", helper)


if __name__ == "__main__":
    unittest.main()
