"""Portable failure controls for the all-page native matrix probe, not UI execution.

The probe itself needs macOS and SwiftUI; these tests keep the parts that can be checked
anywhere honest: the assertion plumbing really can go red, every required surface stays in
the probe, the runner stays macOS-guarded and synthetic, and the probe never requests system
access or presses a capture/monitor toggle.
"""
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROBE = ROOT / "scripts/allpage_matrix_probe.swift"
RUNNER = ROOT / "scripts/check_allpage_matrix.sh"
INTEGRATION = ROOT / "scripts/check_integration.sh"

REQUIRED_GROUPS = [
    "settings panes",
    "settings failure paths",
    "dashboard tabs",
    "dashboard task and project actions",
    "welcome states",
    "details historical and error states",
    "week keyboard",
    "clips keyboard",
    "effective enlarged type",
    "effective contrast states",
]


class AllPageMatrixProbeTests(unittest.TestCase):
    def setUp(self):
        self.source = PROBE.read_text()

    def test_every_required_group_runs_and_the_assertion_set_is_large(self):
        for group in REQUIRED_GROUPS:
            self.assertIn(f'await report.group("{group}")', self.source, group)
        self.assertGreaterEqual(self.source.count("report.require("), 84)
        self.assertNotIn("XCTSkip", self.source)
        # Two settling waits only: no retry-by-sleep anywhere in the probe.
        self.assertEqual(self.source.count("Task.sleep"), 2)
        self.assertLessEqual(self.source.count("for _ in 0..<"), 4)

    def test_native_reader_retains_semantics_and_focus_diagnostics(self):
        for getter in ("accessibilityChildrenInNavigationOrder", "isAccessibilityFocused", "isAccessibilityEnabled"):
            self.assertIn(getter, self.source)
        self.assertIn("@convention(c) (AnyObject, Selector) -> Bool", self.source)
        self.assertIn("if semanticFocus.count == 1", self.source)
        self.assertIn("node.focused == true", self.source)
        for trace in ("before Tab", "after Tab", "nextValidKeyView", "roleFallback=", "identityFallback="):
            self.assertIn(trace, self.source)
        self.assertIn("view.environment(\\.accessibilityEnabled, true)", self.source)
        self.assertIn("let point = CGPoint(x: local.midX, y: local.midY)", self.source)
        self.assertNotIn("host.bounds.height - local.midY", self.source)

    def test_native_contrast_uses_the_requested_appearance_without_competing_scheme(self):
        section = self.source.split("func contrastStates()", 1)[1]
        self.assertNotIn(".environment(\\.colorScheme, scheme)", section)
        self.assertIn("effective == appearanceName.rawValue", section)
        self.assertIn("ratio >= 4.5", section)
        self.assertIn("lowRatio < 4.5", section)
        self.assertIn("host.appearance = appearance", self.source)

    def test_assertion_plumbing_can_go_red(self):
        plumbing = self.source.split("struct MatrixFailure", 1)[1].split("// MARK: - System accessibility layer", 1)[0]
        program = (
            "import Foundation\n\nstruct MatrixFailure"
            + plumbing
            + """
let report = MatrixReport()
func rejects(_ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw MatrixFailure(label: "negative control passed when it had to fail")
}
try report.require(true, "passes")
try rejects { try report.require(false, "fails") }
try rejects { try report.require(false, "fails", "detail") }
await report.group("caught group") { throw MatrixFailure(label: "group body red") }
print("passed=\\(report.passed.count) failed=\\(report.failed.count)")
if report.passed.count != 1 || report.failed.count != 1 { exit(1) }
if !report.failed.first!.hasPrefix("caught group: group body red") { exit(1) }
print("Matrix assertion plumbing check passed")
"""
        )
        swift = shutil.which("swiftc")
        if swift is None:
            self.fail("Swift is required to verify the assertion plumbing")
        with tempfile.TemporaryDirectory() as directory:
            main = pathlib.Path(directory) / "main.swift"
            main.write_text(program)
            binary = pathlib.Path(directory) / "plumbing"
            compiled = subprocess.run(
                [swift, "-swift-version", "6", str(main), "-o", str(binary)],
                capture_output=True, text=True,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn("Matrix assertion plumbing check passed", result.stdout)

    def test_probe_never_requests_access_or_presses_a_monitor(self):
        for forbidden in (
            "requestAccess",
            "requestAuthorization",
            "requestFullAccessToReminders",
            "SMAppService.mainApp.register",
            "EKEventStore().request",
            "NSPasteboard.general.clearContents",
            "NSPasteboard.general.setString",
            "clips.copy(",
        ):
            self.assertNotIn(forbidden, self.source, forbidden)
        # The only AX presses are the Welcome call to action and none of them is a permission or
        # capture control.
        presses = re.findall(r"(?<!func )mxPress\(([^)]*)\)", self.source)
        self.assertEqual(len(presses), 1, presses)
        for hit in presses:
            self.assertNotIn("Allow", hit)
            self.assertNotIn("screenshots", hit)
            self.assertNotIn("copied items", hit)

    def test_measurements_read_the_system_accessibility_tree(self):
        # Other groups retain the system reader; the workspace graphs are read on
        # main through native accessibility objects, never self-addressed AX IPC.
        reader = self.source.split("enum MatrixAXReader {", 1)[1].split("private enum MatrixViewReader", 1)[0]
        for attribute in ("AXUIElementCreateApplication(getpid())", "kAXWindowsAttribute",
                          "kAXChildrenAttribute", "kAXFocusedUIElementAttribute"):
            self.assertIn(attribute, reader)
        self.assertNotIn("accessibilityChildren", reader)
        view_reader = self.source.split("private enum MatrixViewReader {", 1)[1].split("@MainActor\nenum MatrixAX", 1)[0]
        self.assertIn("@MainActor\nprivate enum MatrixViewReader", self.source)
        self.assertIn('precondition(Thread.isMainThread', view_reader)
        for getter in ("accessibilityChildren", "accessibilityContents", "accessibilityRole",
                       "accessibilityLabel", "accessibilityValue", "accessibilityFrame"):
            self.assertIn(getter, view_reader)
        for native_path in ("NSApp.windows", "window.contentView", "view.subviews", "firstResponder"):
            self.assertIn(native_path, view_reader)
        self.assertIn("result.nodes.count >= 3000", view_reader)
        self.assertNotIn("AXUIElement", view_reader)
        # A silent fallback to the trapping backend must fail this guard.
        for start, end in (("func detailsStates()", "func workspaceFixture"),
                           ("func weekKeyboard()", "func clipsKeyboard")):
            group = self.source.split(start, 1)[1].split(end, 1)[0]
            self.assertIn("MatrixAX.useViewTree = true", group)
            self.assertIn("defer { MatrixAX.useViewTree = false }", group)
            self.assertLess(group.index("MatrixAX.useViewTree = true"), group.index("await mxReady"))
        refresh = self.source.split("static var useViewTree", 1)[1].split("func mxApp()", 1)[0]
        self.assertRegex(refresh, r"if useViewTree\s*\{[^}]*snapshot = MatrixViewReader\.read\(\)")
        self.assertRegex(refresh, r"else\s*\{\s*snapshot = await MatrixAXReader\.snapshot\(\)")

    def test_ax_reads_run_off_main_and_only_snapshots_cross_the_actor(self):
        reader = self.source.split("enum MatrixAXReader {", 1)[1].split("private enum MatrixViewReader", 1)[0]
        consumers = self.source.split("@MainActor\nenum MatrixAX", 1)[1]
        self.assertIn('precondition(!Thread.isMainThread', reader)
        self.assertIn('AXUIElementCopyAttributeValue', reader)
        self.assertIn('AX copy \\(context) \\(attribute) error=\\(error.rawValue)', reader)
        self.assertIn('AX before \\(context) attribute=\\(attribute)', reader)
        self.assertIn('let trace = smoke || index < 25', reader)
        self.assertIn('node=\\(index) role=\\(role)', reader)
        self.assertIn('private static let queue = DispatchQueue(', reader)
        self.assertIn('await withCheckedContinuation', reader)
        self.assertIn('queue.async {', reader)
        self.assertIn('continuation.resume(returning: read(smoke: smoke))', reader)
        self.assertNotIn('MainActor.assumeIsolated', reader)
        self.assertIn('await MatrixAX.refresh()', consumers)
        self.assertNotIn('AXUIElementCopy', consumers)
        self.assertNotIn('AXUIElementSetMessagingTimeout', self.source)
        self.assertIn('struct MatrixAXSnapshot: Sendable', self.source)
        self.assertIn('struct MatrixElement: Hashable, Sendable', self.source)
        self.assertIn('exit(hasWindow ? 0 : 1)', consumers)

    def test_focus_membership_compiles_with_snapshot_values(self):
        declaration_match = re.search(r"struct MatrixElement[^\n]+", self.source)
        expression_match = re.search(r"let inWorkspace = [^\n]+", self.source)
        assert declaration_match is not None
        assert expression_match is not None
        declaration = declaration_match.group(0)
        expression = expression_match.group(0)
        swift = shutil.which("swiftc")
        assert swift is not None, "Swift is required to verify snapshot membership"
        program = "import Foundation\nimport CoreFoundation\n" + declaration + "\n" + '''
func mxTree(_ root: MatrixElement) -> [MatrixElement] { [root] }
func check(_ root: MatrixElement, _ focused: MatrixElement) -> Bool {
''' + expression + '''
    return inWorkspace
}
let root = MatrixElement(id: 5)
precondition(check(root, MatrixElement(id: 5)))
precondition(!check(root, MatrixElement(id: 6)))
print("Snapshot focus membership positive and negative controls passed")
'''
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / "main.swift"
            binary = pathlib.Path(directory) / "membership"
            source.write_text(program)
            compile_result = subprocess.run(
                [swift, "-swift-version", "6", str(source), "-o", str(binary)],
                capture_output=True, text=True,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("positive and negative controls passed", result.stdout)
            # The exact stale CF consumer from the failed native head must not compile.
            source.write_text(program.replace("$0 == focused", "CFEqual($0, focused)"))
            broken = subprocess.run(
                [swift, "-swift-version", "6", str(source), "-o", str(binary)],
                capture_output=True, text=True,
            )
            self.assertNotEqual(broken.returncode, 0)
            self.assertIn("class", broken.stderr)

    def test_negative_controls_cover_the_measured_groups(self):
        self.assertIn("negative control: a fixed-size control does not grow", self.source)
        self.assertIn("negative control: a low-contrast label is detected", self.source)

    def test_runner_rejects_non_macos_before_building(self):
        with tempfile.TemporaryDirectory() as directory:
            uname = pathlib.Path(directory) / "uname"
            uname.write_text("#!/bin/sh\nprintf '%s\\n' Linux\n")
            uname.chmod(0o755)
            result = subprocess.run(
                ["bash", str(RUNNER), directory],
                env=dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"]),
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("requires macOS", result.stderr)
            self.assertFalse((pathlib.Path(directory) / "planner.json").exists())

    def test_runner_is_synthetic_and_wired_into_an_existing_job(self):
        runner = RUNNER.read_text()
        self.assertIn("mktemp -d", runner)
        self.assertIn("cp -R \"$ROOT/Sources\" \"$ROOT/Tests\"", runner)
        self.assertIn("Sources/Perch/main.swift", runner)
        self.assertIn("MATRIX_OUTPUT", runner)
        # Real Tab traversal needs full keyboard access as an argument-domain override.
        self.assertIn("'-AppleKeyboardUIMode', '3'", runner)
        # The contrast group needs the system increase-contrast state and restores it afterwards.
        self.assertIn("com.apple.universalaccess", runner)
        self.assertIn("increaseContrast", runner)
        self.assertIn("restored", runner)
        self.assertIn("PERCH_DATA", runner)
        self.assertIn("catchCopies': False", runner)
        self.assertIn("catchScreenshots': False", runner)
        # Reuses the existing behaviour-probe job through its integration step: no new CI job.
        self.assertIn("check_allpage_matrix.sh", INTEGRATION.read_text())
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertEqual(workflow.count("check_allpage_matrix.sh"), 0)


if __name__ == "__main__":
    unittest.main()
