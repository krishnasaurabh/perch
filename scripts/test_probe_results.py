"""Portable wrapper/report controls; synthetic payloads are not native evidence."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("probe_results", ROOT / "scripts/check_probe_results.py")
assert spec is not None and spec.loader is not None
results = importlib.util.module_from_spec(spec)
spec.loader.exec_module(results)


def integration_report():
    required = [f"settings {p} pane renders its content" for p in
                ("general", "notch", "calendar", "agents", "data")]
    required += [f"dashboard {p} tab renders its content" for p in
                 ("Upcoming", "History", "Insights", "Projects")]
    required += ["welcome never rewrites unreadable planner data", "failed details save keeps the draft",
                 "Command-Z restores the deleted project and its task links"]
    return {"passed": required + [f"fixture {i}" for i in range(60)], "failed": []}


def theme_report():
    rows = [{"page": p, "state": s} for p in results.THEME_PAGES for s in results.THEME_STATES]
    names = [f"{r['page']} [{r['state']}]: synthetic gate" for r in rows]
    return {"rows": rows, "passed": names + [f"fixture {i}" for i in range(330 - len(names))], "failed": []}


def clips_report():
    source = (ROOT / "scripts/clips_layout_probe.swift").read_text()
    array = source.split("let clipsKeyboardAssertions = [", 1)[1].split("]", 1)[0]
    labels = re.findall(r'"([^"]+)"', array)
    return [{"broken": "", "red": "", "ok": True,
             "passed": ["week fixture", "week fixture"] + labels[:9]
                       + ["clips fixture", "clips fixture"] + labels[9:]}]


class ProbeReportTests(unittest.TestCase):
    def test_complete_synthetic_reports(self):
        for kind, report in (("integration", integration_report()), ("theme", theme_report()),
                             ("clips", clips_report())):
            self.assertGreater(results.validate(kind, report), 0)

    def test_failures_and_missing_failure_lists_are_rejected(self):
        for kind, build in (("integration", integration_report), ("theme", theme_report)):
            for failure in (["deliberate red"], None):
                report = build()
                report["failed"] = failure
                with self.subTest(kind=kind, failure=failure), self.assertRaises(ValueError):
                    results.validate(kind, report)

    def test_every_theme_capture_is_mandatory_and_unique(self):
        for index in range(len(theme_report()["rows"])):
            report = theme_report()
            report["rows"].pop(index)
            with self.subTest(index=index), self.assertRaises(ValueError):
                results.validate("theme", report)
        report = theme_report()
        report["rows"][-1] = report["rows"][0]
        with self.assertRaises(ValueError):
            results.validate("theme", report)
        report = theme_report()
        report["passed"] = report["passed"][:329]
        with self.assertRaises(ValueError):
            results.validate("theme", report)

    def test_settings_reports_use_all_five_current_panes(self):
        panes = {"general", "notch", "calendar", "agents", "data"}
        self.assertEqual({p for p in results.THEME_PAGES if p.startswith("settings-")},
                         {f"settings-{p}" for p in panes})
        for pane in panes:
            report = integration_report()
            label = f"settings {pane} pane renders its content"
            report["passed"].remove(label)
            with self.subTest(pane=pane), self.assertRaises(ValueError):
                results.validate("integration", report)
        # Retired identities cannot fill in for the new pages, even with enough total assertions.
        report = integration_report()
        report["passed"] = [label for label in report["passed"] if not label.startswith("settings ")]
        report["passed"] += [f"settings {p} pane renders its content"
                             for p in ("General", "Workspace", "Focus timer", "AI agents", "System")]
        with self.assertRaises(ValueError):
            results.validate("integration", report)

    def test_theme_rejects_retired_settings_captures(self):
        report = theme_report()
        for row in report["rows"]:
            if row["page"] == "settings-calendar":
                row["page"] = "settings-System"
        with self.assertRaises(ValueError):
            results.validate("theme", report)

    def test_native_settings_marker_arrays_use_real_panes_and_content(self):
        view = (ROOT / "Sources/PerchApp/Settings/SettingsView.swift").read_text()
        match = re.search(r"case (general, notch, calendar, agents, data)", view)
        assert match is not None
        cases = match.group(1)
        pane_files = {p: (ROOT / f"Sources/PerchApp/Settings/Settings{p.title()}Pane.swift").read_text()
                      for p in cases.split(", ")}
        pane_files["agents"] += (ROOT / "Sources/PerchApp/Settings/AgentsSettings.swift").read_text()
        programs = []
        for file, end in (("integration_probe.swift", "var previous:"),
                          ("allpage_matrix_probe.swift", "var observed:")):
            source = (ROOT / "scripts" / file).read_text()
            array = source.split("let markers: [(SettingsView.Pane,", 1)[1].split(end, 1)[0]
            declaration = "let markers: [(SettingsView.Pane," + array
            entries = re.findall(r'\(\.(\w+), "([^"]+)"(?:, "([^"]+)")?\)', array)
            self.assertEqual([p for p, _, _ in entries], cases.split(", "))
            for pane, first, second in entries:
                for marker in (first, second):
                    if marker:
                        self.assertIn(marker.lower(), pane_files[pane].lower(), (file, pane, marker))
            programs.append("enum SettingsView { enum Pane: String { case " + cases + " } }\n" + declaration)
        swift = shutil.which("swiftc")
        assert swift is not None
        with tempfile.TemporaryDirectory() as directory:
            for index, program in enumerate(programs):
                path = Path(directory) / f"markers{index}.swift"
                path.write_text(program)
                built = subprocess.run([swift, "-swift-version", "6", "-typecheck", str(path)],
                                       capture_output=True, text=True)
                self.assertEqual(built.returncode, 0, built.stderr)

    def test_settings_navigation_keeps_real_keyboard_and_button_identity(self):
        integration = (ROOT / "scripts/integration_probe.swift").read_text()
        settings = integration.split("func checkSettingsMatrix(", 1)[1].split("func checkDashboardMatrix(", 1)[0]
        self.assertNotIn("NSTableView", settings)
        self.assertNotIn("selectedRow", settings)
        self.assertIn("matrixSettingsFocused", settings)
        self.assertIn('matrixKey(window, 48, "\\t")', settings)
        self.assertIn('matrixKey(window, 125, "\\u{f701}")', settings)
        self.assertIn("navigation.pane == pane", settings)
        self.assertNotIn("navigation.pane = pane", settings)
        theme = (ROOT / "scripts/theme_probe.swift").read_text()
        self.assertNotIn("firstTable", theme)
        self.assertIn("settingsSidebarFocused", theme)
        self.assertIn("navigation.pane == pane", theme)
        self.assertIn('"settings-calendar"', theme)
        for source, start, end in (
                (integration, "func matrixSettingsFocused(", "func checkSettingsMatrix("),
                (theme, "func settingsSidebarFocused(", "func measureEffectiveStates(")):
            walker = source.split(start, 1)[1].split(end, 1)[0]
            for selector in ("accessibilityChildren", "accessibilityContents",
                             "accessibilityChildrenInNavigationOrder", "isAccessibilityFocused"):
                self.assertIn(selector, walker)
            self.assertIn("subviews", walker)
            self.assertIn("@convention(c) (AnyObject, Selector) -> Bool", walker)
        matrix = (ROOT / "scripts/allpage_matrix_probe.swift").read_text()
        selector = matrix.split("func selectPane(", 1)[1].split("// MARK:", 1)[0]
        self.assertIn('"settings.sidebar.\\(pane.rawValue)"', selector)
        self.assertIn('mxRole($0) == "AXButton"', selector)
        self.assertIn("mxClick(", selector)
        self.assertNotIn('contains("Row")', selector)

    def test_settings_enablement_reads_only_a_unique_checkbox(self):
        source = (ROOT / "scripts/allpage_matrix_probe.swift").read_text()
        helper_start = "@MainActor\nfunc mxSettingsCheckboxEnabled("
        self.assertIn(helper_start, source)
        declarations = source.split("struct MatrixFailure:", 1)[1].split("/// Unbuffered", 1)[0]
        declarations = "struct MatrixFailure:" + declarations
        declarations += "struct MatrixElement:" + source.split("struct MatrixElement:", 1)[1].split(
            "/// All native AX calls", 1)[0]
        declarations += "@MainActor\nfunc mxString(" + source.split("@MainActor\nfunc mxString(", 1)[1].split(
            "@MainActor\nfunc mxIdentifier(", 1)[0]
        declarations += "@MainActor\nfunc mxNames(" + source.split("@MainActor\nfunc mxNames(", 1)[1].split(
            "@MainActor\nfunc mxName(", 1)[0]
        declarations += helper_start + source.split(helper_start, 1)[1].split(
            "@MainActor\nfunc mxIdentified(", 1)[0]
        program = r'''
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
let kAXRoleAttribute = "AXRole"
let kAXChildrenAttribute = "AXChildren"
let kAXDescriptionAttribute = "AXDescription"
let kAXTitleAttribute = "AXTitle"
let kAXValueAttribute = "AXValue"
let kAXHelpAttribute = "AXHelp"
@MainActor enum MatrixAX { static var snapshot = MatrixAXSnapshot() }
@MainActor enum MatrixStage { static func mark(_ stage: String) {} }
''' + declarations + r'''
@MainActor
func fixture(_ name: String, _ role: String = "AXCheckBox", enabled: Bool?,
             labelEnabled: Bool? = true, nameAttribute: String = "AXDescription",
             duplicate: Bool = false, labelFirst: Bool = true) -> MatrixElement {
    let root = MatrixElement(id: 0), label = MatrixElement(id: 1)
    let control = MatrixElement(id: 2), other = MatrixElement(id: 3)
    let duplicateControl = MatrixElement(id: 4)
    var children = labelFirst ? [label, control, other] : [control, label, other]
    if duplicate { children.append(duplicateControl) }
    MatrixAX.snapshot = MatrixAXSnapshot(nodes: [
        root: MatrixAXNode(edges: ["AXChildren": children]),
        label: MatrixAXNode(strings: ["AXRole": "AXStaticText", "AXValue": name], enabled: labelEnabled),
        control: MatrixAXNode(strings: ["AXRole": role, nameAttribute: name], enabled: enabled),
        other: MatrixAXNode(strings: ["AXRole": "AXCheckBox", "AXDescription": name + " other"], enabled: true),
        duplicateControl: MatrixAXNode(strings: ["AXRole": "AXCheckBox", "AXDescription": name], enabled: enabled),
    ])
    return root
}
@MainActor
func expectFailure(_ name: String, root: MatrixElement, fragment: String) {
    do {
        _ = try mxSettingsCheckboxEnabled(root, name: name)
        fatalError("accepted invalid checkbox: \(fragment)")
    } catch let error as MatrixFailure {
        precondition(error.label.contains(name), "failure must name its control")
        precondition(error.label.contains(fragment), error.label)
    } catch { fatalError("unexpected error: \(error)") }
}
MainActor.assumeIsolated {
    for name in ["Auto-sort new tasks", "Alert on iPhone and Apple Watch too"] {
        for enabled in [false, true] {
            for labelEnabled: Bool? in [nil, false, true] {
                for labelFirst in [false, true] {
                    for attribute in ["AXDescription", "AXTitle", "AXValue", "AXHelp"] {
                        let root = fixture(name, enabled: enabled, labelEnabled: labelEnabled,
                                           nameAttribute: attribute, labelFirst: labelFirst)
                        let observed = try! mxSettingsCheckboxEnabled(root, name: name)
                        precondition(observed == enabled, "read label state instead of checkbox state")
                    }
                }
            }
        }
        let root = fixture(name, enabled: true)
        MatrixAX.snapshot.nodes[MatrixElement(id: 0)]?.edges["AXChildren"] = [MatrixElement(id: 1)]
        expectFailure(name, root: root, fragment: "saw 0")
        for role in ["AXStaticText", "AXButton", "AXSwitch", "AXUnknown"] {
            expectFailure(name, root: fixture(name, role, enabled: true), fragment: "saw 0")
        }
        for enabled in [false, true] {
            expectFailure(name, root: fixture(name, enabled: enabled, duplicate: true), fragment: "saw 2")
        }
        expectFailure(name, root: fixture(name, enabled: nil), fragment: "missing enabled state")
    }
}
print("settings checkbox selector controls passed")
'''
        swift = shutil.which("swiftc")
        assert swift is not None
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "settings-checkbox.swift"
            path.write_text(program)
            executable = Path(directory) / "settings-checkbox"
            built = subprocess.run([swift, "-swift-version", "6", str(path), "-o", str(executable)],
                                   capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            ran = subprocess.run([str(executable)], capture_output=True, text=True)
            self.assertEqual(ran.returncode, 0, ran.stderr)
            self.assertIn("settings checkbox selector controls passed", ran.stdout)

    def test_settings_enablement_assertions_use_strict_checkbox_lookup(self):
        source = (ROOT / "scripts/allpage_matrix_probe.swift").read_text()
        settings = source.split("func settingsFailurePaths()", 1)[1].split("// MARK: Dashboard", 1)[0]
        for variable, title, expected in (
                ("autoSortEnabled", "Auto-sort new tasks", "AISorter.isSupported"),):
            call = rf'let {variable} = try mxSettingsCheckboxEnabled\(\s*root, name: AppL10n.text\("{title}"\)\)'
            self.assertRegex(settings, call)
            self.assertIn(f"{variable} == {expected}", settings)
        for title in ("Ignore", "Bring back"):
            for enabled in ("false", "true"):
                self.assertIn(f'name: "{title}", expectedEnabled: {enabled}', settings)
        self.assertNotIn('AppL10n.text("Alert on iPhone and Apple Watch too")', settings)
        self.assertNotIn("mxFind(", settings)
        selector = settings.split("func calendarSegment(", 1)[1].split("// Reading", 1)[0]
        self.assertIn("groups.count == 1", selector)
        self.assertIn("matches.count == 1", selector)
        self.assertIn("enabled == expectedEnabled", selector)

    def test_every_keyboard_assertion_is_mandatory(self):
        for index in range(19):
            report = clips_report()
            report[0]["passed"].remove(results.CLIPS_KEYBOARD_ASSERTIONS[index])
            with self.subTest(index=index), self.assertRaises(ValueError):
                results.validate("clips", report)
        for key, value in (("ok", False), ("red", "wrong")):
            report = clips_report()
            report[0][key] = value
            with self.assertRaises(ValueError):
                results.validate("clips", report)

    def test_native_keyboard_report_includes_all_fixture_preconditions(self):
        report = clips_report()
        self.assertEqual(len(report[0]["passed"]), 23)
        self.assertEqual(results.validate("clips", report), 19)
        for label in ("week fixture", "clips fixture"):
            for mutation in ("missing", "duplicate", "unknown"):
                broken = copy.deepcopy(report)
                if mutation == "duplicate":
                    broken[0]["passed"].append(label)
                else:
                    broken[0]["passed"].remove(label)
                    if mutation == "unknown":
                        broken[0]["passed"].append("unknown fixture")
                with self.subTest(label=label, mutation=mutation), self.assertRaises(ValueError):
                    results.validate("clips", broken)

    def test_keyboard_identity_cannot_be_replaced_or_duplicated(self):
        for label in results.CLIPS_KEYBOARD_ASSERTIONS:
            for mutation in ("duplicate", "same-prefix replacement"):
                report = clips_report()
                if mutation == "duplicate":
                    report[0]["passed"].append(label)
                else:
                    index = report[0]["passed"].index(label)
                    report[0]["passed"][index] = label + " unexpected"
                with self.subTest(label=label, mutation=mutation), self.assertRaises(ValueError):
                    results.validate("clips", report)
        report = clips_report()
        interactions = [label for label in report[0]["passed"] if ":" in label]
        self.assertEqual(interactions, list(results.CLIPS_KEYBOARD_ASSERTIONS))

    def test_keyboard_report_rejects_invalid_labels_and_collections(self):
        for value in (None, {}, "not a list", [None], [[]]):
            report = clips_report()
            report[0]["passed"] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                results.validate("clips", report)

    def test_keyboard_control_must_fail_its_exact_assertion(self):
        report = clips_report()
        report.append({"broken": "expected", "red": "different", "ok": True, "passed": []})
        with self.assertRaises(ValueError):
            results.validate("clips", report)

    def test_missing_report_cli_is_red(self):
        with tempfile.TemporaryDirectory() as directory:
            run = subprocess.run([sys.executable, str(ROOT / "scripts/check_probe_results.py"),
                                  "theme", str(Path(directory) / "absent.json")], capture_output=True, text=True)
            self.assertNotEqual(run.returncode, 0)
            self.assertIn("FAIL: theme", run.stderr)

    def test_wrappers_fail_before_any_build_on_linux(self):
        with tempfile.TemporaryDirectory() as directory:
            uname = Path(directory) / "uname"
            uname.write_text("#!/bin/sh\nprintf 'Linux\\n'\n")
            uname.chmod(0o755)
            for name in ("integration", "theme", "clips_layout"):
                run = subprocess.run(["bash", str(ROOT / f"scripts/check_{name}.sh"), directory],
                                     env=dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"]),
                                     capture_output=True, text=True)
                self.assertEqual(run.returncode, 2, run.stderr)
            self.assertFalse((Path(directory) / "planner.json").exists())

    def test_wrappers_enforce_native_reports_and_bounded_builds(self):
        for name, report in (("integration", "integration-matrix.json"), ("theme", "measured-states.json"),
                             ("clips_layout", "clips-keyboard.json")):
            source = (ROOT / f"scripts/check_{name}.sh").read_text()
            self.assertIn("set -euo pipefail", source)
            self.assertIn("check_probe_results.py", source)
            self.assertIn(report, source)
            for build in (line for line in source.splitlines() if "swift build" in line):
                self.assertIn("--jobs 2", build)
                self.assertIn("-enable-testing", build)

    def test_launchers_propagate_exit_and_timeout_and_disable_capture(self):
        for name in ("integration", "theme", "clips"):
            path = ROOT / ("scripts/run_clips_probe.py" if name == "clips" else f"scripts/check_{name}.sh")
            source = path.read_text()
            code = source if name == "clips" else source.split("<<'PY'\n", 1)[1].split("\nPY", 1)[0]
            with tempfile.TemporaryDirectory() as directory:
                with patch.object(sys, "argv", [str(path), "/synthetic-binary", directory]), \
                     patch("subprocess.run") as run:
                    exec(compile(code, str(path), "exec"), {})
                args, kwargs = run.call_args
                self.assertEqual(args[0][0], "/synthetic-binary")
                self.assertIs(kwargs["check"], True)
                self.assertGreaterEqual(kwargs["timeout"], 120)
                planner = json.loads(Path(kwargs["env"]["PERCH_DATA"]).read_text())
                self.assertIs(planner["preferences"]["catchCopies"], False)
                self.assertIs(planner["preferences"]["catchScreenshots"], False)
                for failure in (subprocess.CalledProcessError(1, "probe"),
                                subprocess.TimeoutExpired("probe", kwargs["timeout"])):
                    with patch.object(sys, "argv", [str(path), "/synthetic-binary", directory]), \
                         patch("subprocess.run", side_effect=failure), self.assertRaises(type(failure)):
                        exec(compile(code, str(path), "exec"), {})

    def test_keyboard_products_opt_into_concrete_focus_registration(self):
        projects = (ROOT / "Sources/PerchApp/Settings/ProjectsList.swift").read_text()
        clips = (ROOT / "Sources/PerchApp/Workspace/ClipsPage.swift").read_text()
        style = (ROOT / "Sources/PerchApp/Workspace/Components/ControlStyle.swift").read_text()
        self.assertIn("ProjectDeleteButton {", projects)
        self.assertIn("@FocusState private var focused: Bool", projects)
        self.assertIn(".buttonStyle(PillStyle(focus: $focused))", projects)
        self.assertIn(".focusable(enabled)\n                    .focused(externalFocus)", style)
        self.assertIn(".focusable()\n                .focused($copyFocused)", clips)
        self.assertIn("focused: copyFocused", clips)
        self.assertIn("clips.copy(clip)", clips)
        self.assertIn("Button(action: copyClip)", clips)
        for source in (projects, clips):
            self.assertIn(".onKeyPress(.space, phases: .down)", source)
            self.assertNotIn(".onKeyPress(.space, phases: .all)", source)

    def test_keyboard_activation_consumes_once_and_rejects_disabled(self):
        swift = shutil.which("swiftc")
        assert swift is not None
        sources = [
            ("project", ROOT / "Sources/PerchApp/Settings/ProjectsList.swift"),
            ("clip", ROOT / "Sources/PerchApp/Workspace/ClipsPage.swift"),
        ]
        functions = []
        for name, path in sources:
            source = path.read_text()
            match = re.search(r'\.onKeyPress\(\.space, phases: \.down\) \{ _ in\n(.*?)\n\s*\}', source, re.S)
            self.assertIsNotNone(match, path)
            body = match.group(1)
            functions.append(f"func {name}(_ enabled: Bool, action: () -> Void, copyClip: () -> Void) -> Result {{\n{body}\n}}")
        program = "enum Result { case handled, ignored }\n" + "\n".join(functions) + '''
for handler in [project, clip] {
    var count = 0
    let action = { count += 1 }
    precondition(handler(false, action, action) == .ignored)
    precondition(count == 0)
    precondition(handler(true, action, action) == .handled)
    precondition(count == 1)
}
'''
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "main.swift"
            source.write_text(program)
            binary = Path(directory) / "activation"
            built = subprocess.run([swift, str(source), "-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            ran = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(ran.returncode, 0, ran.stderr)

    def test_integration_accumulator_keeps_every_failure(self):
        swift = shutil.which("swiftc")
        assert swift is not None, "Swift is required for accumulator controls"
        source = (ROOT / "scripts/integration_probe.swift").read_text()
        code = source[source.index("@MainActor\nenum MatrixChecks"):source.index("@MainActor\nfunc matrixSettle")]
        program = 'import Foundation\n' + code + '''
@main struct Entry {
    @MainActor static func main() {
        matrixRequire(false, "first red")
        matrixRequire(true, "green")
        matrixRequire(false, "second red")
        precondition(MatrixChecks.failures == ["first red", "second red"])
        precondition(MatrixChecks.passed == ["green"])
        exit(MatrixChecks.failures.isEmpty ? 0 : 1)
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "control.swift"
            path.write_text(program)
            binary = Path(directory) / "control"
            built = subprocess.run([swift, "-swift-version", "6", "-parse-as-library", str(path), "-o", str(binary)],
                                   capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 1)
            self.assertIn("first red", run.stderr)
            self.assertIn("second red", run.stderr)


if __name__ == "__main__":
    unittest.main()
