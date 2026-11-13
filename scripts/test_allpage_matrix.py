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

    def test_native_fixture_retains_identity_and_sets_the_measured_page(self):
        self.assertIn("withExtendedLifetime(retained)", self.source)
        self.assertIn("if !MatrixAX.publicationPrimed", self.source)
        activation = self.source.split("static func activateWindowRoots()", 1)[1].split("static func raw(", 1)[0]
        self.assertIn("elements(app, kAXWindowsAttribute", activation)
        self.assertIn("elements(window, kAXChildrenAttribute", activation)
        self.assertNotIn("stack", activation)
        self.assertIn("retained[handle(child)] = child", self.source)
        self.assertIn('value(owner, "accessibilityFocusedUIElement")', self.source)
        self.assertIn('value(object, "accessibilityTitleUIElement")', self.source)
        self.assertIn("host.sizingOptions = []", self.source)
        self.assertNotIn("AnyView(view.environment", self.source)
        week = self.source.split("func weekKeyboard()", 1)[1].split("func clipsKeyboard()", 1)[0]
        self.assertLess(week.index("fixture.model.page = .week"), week.index("matrixWindow("))
        clips = self.source.split("func clipsKeyboard()", 1)[1].split("func enlargedType()", 1)[0]
        self.assertLess(clips.index("guard let first = clips.clips.first"), clips.index('clips.add(.text("Matrix clip two")'))
        self.assertNotIn("cancelTracking()", self.source)
        self.assertIn("matrix menu: posted real Escape", self.source)
        self.assertIn("RunLoop.main.add(timer, forMode: .eventTracking)", self.source)

    def test_traversal_measures_appkit_keyboard_access_and_reads_focus_honestly(self):
        # AppKit's effective full keyboard access is asserted, not inferred from defaults.
        self.assertIn("NSApp.isFullKeyboardAccessEnabled, \"AppKit reports full keyboard access", self.source)
        runner = RUNNER.read_text()
        self.assertIn("'defaults', 'write', '-g', 'AppleKeyboardUIMode', '-int'", runner)
        self.assertIn("full-keyboard-access restored", runner)
        self.assertLess(runner.index("write_keyboard_mode('3')"), runner.index("run('matrix', [])"))
        # Per-Tab census and identity provenance are logged before any assertion.
        for trace in ("KEYVIEW ", "canBecomeKeyView=", "FOCUS step ", "source=\\(mxFocusIdentitySource())",
                      "role-fallback", "matrix focus read: source="):
            self.assertIn(trace, self.source)
        # Duplicate focused semantics collapse to the deepest node; a single candidate is unchanged.
        self.assertIn('source = "semantic-deepest of', self.source)
        self.assertIn("!unique.keys.contains { $0 != key && contained.contains($0) }", self.source)
        self.assertLess(self.source.index("if semanticFocus.count == 1 {\n            result.focused"),
                        self.source.index("} else if deepest.count == 1 {"))
        # Focus objects are attached only after the window walk, never pre-marked discovered.
        reader = self.source.split("private enum MatrixViewReader", 1)[1].split("enum MatrixAX {", 1)[0]
        self.assertNotIn('as? NSObject,\n                discovered.insert(handle(focused))', reader)
        self.assertLess(reader.index("walk()\n        let windowReachable"),
                        reader.index("+ detachedFocus\n"))

    def test_native_contrast_uses_the_requested_appearance_without_competing_scheme(self):
        section = self.source.split("func contrastStates()", 1)[1]
        self.assertNotIn(".environment(\\.colorScheme, scheme)", section)
        self.assertIn("effective == appearanceName.rawValue", section)
        self.assertIn("ratio >= 4.5", section)
        self.assertIn("lowRatio < 4.5", section)
        self.assertIn("host.appearance = appearance", self.source)

    def test_contrast_reads_the_variant_by_best_match_not_the_base_name(self):
        section = self.source.split("func contrastStates()", 1)[1].split("func mxHex(", 1)[0]
        # NSAppearance.name reports the base name even for a high-contrast object, so a
        # name comparison can never observe the variant; bestMatch(from:) resolves it.
        self.assertIn("window.effectiveAppearance.bestMatch(from: [baseName, appearanceName])", section)
        self.assertNotIn("let effective = window.effectiveAppearance.name.rawValue", section)
        self.assertIn("NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast", section)
        # The strict expectation stays: the high-contrast variant must be the resolved match.
        self.assertIn("effective == appearanceName.rawValue", section)
        self.assertIn("accessibilityHighContrastDarkAqua", section)
        self.assertIn("accessibilityHighContrastAqua", section)

    def test_focus_seeds_never_detach_window_content(self):
        reader = self.source.split("private enum MatrixViewReader {", 1)[1].split("@MainActor\nenum MatrixAX", 1)[0]
        seeding = reader.split("var detachedFocus", 1)[1].split("func walk()", 1)[0]
        # The focused getter can return the hosting view itself, so marking a focus object
        # discovered before the walk would delete the window -> content edge and detach the page.
        self.assertNotIn("discovered.insert", seeding)
        self.assertIn("detachedFocus.append(focused)", seeding)
        # They are attached only after the window walk, as roots the walk never reached.
        self.assertLess(
            reader.index("walk()\n        let windowReachable"),
            reader.index("+ detachedFocus\n"),
        )
        self.assertIn("if let content = window.contentView { children.append(content) }", reader)
        self.assertIn("result.nodes.count >= 3000", reader)

    def test_focus_seed_ordering_control(self):
        """Model of the reader's two-phase worklist: windows first, then unreached focus roots."""
        graph = {"window": ["content"], "content": ["status", "detail"], "status": [], "detail": []}

        def read(preseed):
            nodes, discovered, edges = {}, {"window"}, {}

            def walk(seed):
                stack = [(seed, 0)]
                while stack:
                    key, depth = stack.pop()
                    if key in nodes:
                        continue
                    children = [c for c in graph[key] if c != key and c not in discovered]
                    discovered.update(children)
                    edges[key] = children
                    nodes[key] = True
                    stack.extend((c, depth + 1) for c in reversed(children))

            if preseed:
                # The baseline: the focus object was marked discovered before the walk, so the
                # window edge to its own content was dropped and the page detached.
                discovered.add("content")
                walk("content")
            walk("window")
            if not preseed and "content" not in discovered:
                # The measured fix: attach focus roots the window walk never reached.
                discovered.add("content")
                walk("content")
            reachable, queue = [], ["window"]
            while queue:
                node = queue.pop()
                reachable.append(node)
                queue.extend(edges.get(node, []))
            return set(nodes), set(reachable)

        old_nodes, old_reachable = read(preseed=True)
        new_nodes, new_reachable = read(preseed=False)
        self.assertEqual(old_nodes, set(graph))
        self.assertNotIn("status", old_reachable)  # the measured red: read, but detached
        self.assertEqual(new_nodes, set(graph))
        self.assertEqual(new_reachable, set(graph))

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
        # Every activation is a real input event, including the Welcome default action.
        self.assertNotIn("AXUIElementPerformAction", self.source)
        self.assertNotIn("accessibilityPerformPress", self.source)
        self.assertNotIn("performClick", self.source)
        self.assertIn('try await mxKey(window, 36, "\\r")', self.source)

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
