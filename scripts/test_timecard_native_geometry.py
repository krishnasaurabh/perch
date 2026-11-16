"""Portable regressions for the time-card native fixtures' geometry and persisted reads.

Native AppKit/SwiftUI hosts cannot run on Linux. These tests compile the REAL portable
WorkspaceLayout/DesignTokens/NotchLayout sources and the REAL helpers and predicates extracted
from the native probes, with minimal stubs only for AppKit/app types. Native execution and
screenshot replay remain macOS CI gates.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FOCUS = ROOT / "scripts/focus_entry_probe.swift"
COMPACT = ROOT / "scripts/compact_home_probe.swift"
THEME = ROOT / "scripts/theme_probe.swift"
PORTABLE_UI = ("WorkspaceLayout", "DesignTokens", "NotchLayout", "TodayTabs")
LEGACY_HEIGHT = 351
STATUS_BAR_THICKNESS = 22  # Stub value, deliberately different from any presented menu-bar height.


def host_helpers(source):
    start = source.index("@MainActor func workspaceHostMenuBarHeight(")
    end = source.index("\n}\n", source.index("@MainActor func workspaceHostHeight(", start)) + 3
    return source[start:end]


def scheduled_body():
    source = FOCUS.read_text()
    return source.split("func verifyScheduledTimeCard(", 1)[1].split("\n}\n", 1)[0]


def workspace_page_extension():
    view = (ROOT / "Sources/PerchApp/Workspace/WorkspaceView.swift").read_text()
    match = re.search(r"extension NotchPage \{\n.*?\n\}\n", view, re.S)
    assert match, "WorkspaceView no longer maps NotchPage to WorkspacePage"
    return match[0]


class TimeCardNativeGeometryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.swiftc = shutil.which("swiftc")
        if cls.swiftc is None:
            raise AssertionError("swiftc is required for the native fixture geometry regressions")
        cls.temp = tempfile.TemporaryDirectory(prefix="timecard-geometry-", dir=os.environ.get("TMPDIR"))
        cls.root = Path(cls.temp.name)
        cls.ui = []
        for name in PORTABLE_UI:
            # Compiled as one module with PlannerCore, so its import is dropped.
            text = (ROOT / f"Sources/PerchUI/{name}.swift").read_text().replace("import PlannerCore\n", "")
            path = cls.root / f"{name}.swift"
            path.write_text(text)
            cls.ui.append(path)
        cls.core = sorted((ROOT / "Sources/PlannerCore").glob("*.swift"))

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def compile(self, name, program, *, with_ui):
        directory = self.root / name
        directory.mkdir(exist_ok=True)
        # Top-level code is only allowed in main.swift of a multi-file module.
        main = directory / "main.swift"
        main.write_text(program)
        binary = directory / name
        assert self.swiftc is not None
        inputs = [*map(str, self.core), *map(str, self.ui)] if with_ui else []
        return subprocess.run(
            [self.swiftc, "-swift-version", "6", *inputs, str(main), "-o", str(binary)],
            capture_output=True, text=True, timeout=300), binary

    # MARK: page-aware direct WorkspaceView hosts

    def test_direct_hosts_share_one_helper_and_drop_the_legacy_height(self):
        focus, compact = FOCUS.read_text(), COMPACT.read_text()
        self.assertEqual(host_helpers(focus), host_helpers(compact))
        for path, source, hosts in (
            (FOCUS, focus, ["height: workspaceHostHeight(model)", "height: workspaceHostHeight(delegate.model)"]),
            (COMPACT, compact, ["let height = workspaceHostHeight(delegate.model)"]),
        ):
            with self.subTest(probe=path.name):
                self.assertNotIn(f"height: {LEGACY_HEIGHT}", source)
                for host in hosts:
                    self.assertEqual(source.count(host), 1, host)
        # Narrow widths stay intentionally narrow; only the height changes.
        self.assertIn('[("normal", CGFloat(820)), ("compact", CGFloat(620))]', focus)
        self.assertIn("width: 820, height: workspaceHostHeight(model)", scheduled_body())
        self.assertIn("for width in [CGFloat(820), CGFloat(620)]", compact)

    def test_helper_matches_workspace_view_band_and_real_layout_height(self):
        view = (ROOT / "Sources/PerchApp/Workspace/WorkspaceView.swift").read_text()
        # The helper mirrors exactly this production fallback for notchHeight 0.
        self.assertIn("model.geometry?.workspacePresentation?.menuBarHeight ?? notchHeight", view)
        self.assertIn("measured > 0 ? measured : NSStatusBar.system.thickness", view)
        program = f'''
import Foundation

struct NSStatusBar {{
    static let system = NSStatusBar()
    let thickness: CGFloat = {STATUS_BAR_THICKNESS}
}}
struct WorkspacePresentation {{ let page: WorkspacePage; let menuBarHeight: CGFloat }}
struct NotchGeometry {{ var workspacePresentation: WorkspacePresentation? }}
enum NotchPage {{ case home, week, clips, insights }}
@MainActor final class NotchModel {{
    var page = NotchPage.home
    var geometry: NotchGeometry?
}}
{workspace_page_extension()}
{host_helpers(FOCUS.read_text())}
@MainActor func run() {{
    let model = NotchModel()
    var rows: [String] = []
    for (presented, page) in [(nil, NotchPage.home), (0, .home), (37, .home), (37, .week), (24, .clips)]
        as [(CGFloat?, NotchPage)]
    {{
        model.page = page
        model.geometry = presented.map {{
            NotchGeometry(workspacePresentation: WorkspacePresentation(page: page.workspacePage, menuBarHeight: $0))
        }}
        rows.append("\\(workspaceHostMenuBarHeight(model)) \\(workspaceHostHeight(model))")
    }}
    print(rows.joined(separator: "|"))
    print(WorkspaceLayout.sheetHeight)
}}
MainActor.assumeIsolated {{ run() }}
'''
        compiled, binary = self.compile("host_height", program, with_ui=True)
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        out = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10, check=True).stdout.split()
        rows = " ".join(out[:-1]).split("|")
        sheet = float(out[-1])
        t = STATUS_BAR_THICKNESS
        expected = [(t, sheet + t), (t, sheet + t), (37, sheet + 37), (37, sheet + 37), (24, sheet + 24)]
        self.assertEqual([tuple(map(float, row.split())) for row in rows], expected)
        for _, height in expected:
            self.assertGreater(height, LEGACY_HEIGHT)

    # MARK: theme fixture uses the production forWorkspace hook

    def test_theme_shell_model_and_screen_share_page_aware_geometry(self):
        source = THEME.read_text()
        self.assertIn("let geometry = baseGeometry.forWorkspace(.home)", source)
        self.assertEqual(source.count("NotchGeometry(\n"), 1)
        loop = source.split("for page in [NotchPage.home, .week] {", 1)[1].split("window.close()", 1)[0]
        open_at = loop.index("model.open(page: page, pinned: true)")
        for line in ("let presented = baseGeometry.forWorkspace(page)", "model.geometry = presented",
                     "screen.geometry = presented", "presented.window == geometry.window"):
            self.assertLess(loop.index(line), open_at, line)
        prelude = source.split("for page in [NotchPage.home, .week] {", 1)[0].rsplit("for light in", 1)[1]
        self.assertIn("render(root, size: geometry.window.size)", prelude)
        # Home/week pairs, focused capture and the measured pass stay intact.
        for kept in ('"\\(mode)-\\(page.rawValue).png"', '"\\(mode)-home-focused.png"',
                     "model.captureFocusRequest = UUID()", "geometry: geometry, output: output)"):
            self.assertIn(kept, source)

    def test_theme_screen_pages_resolve_to_one_window_with_real_layout(self):
        """Both pages fit the fixture screen, so the fixed render window is valid for both."""
        program = '''
import Foundation
let screen = NotchLayout.Screen(
    frame: CGRect(x: 0, y: 0, width: 1024, height: 768), visibleFrame: CGRect(x: 0, y: 0, width: 1024, height: 744))
let home = WorkspaceLayout.frame(screen: screen, page: .today, menuBarHeight: screen.menuBarHeight)
let week = WorkspaceLayout.frame(screen: screen, page: .week, menuBarHeight: screen.menuBarHeight)
let legacy = WorkspaceLayout.frame(screen: screen)
print(home.width, home.height, week.width, week.height, legacy.width, legacy.height, week.contains(home))
'''
        compiled, binary = self.compile("theme_layout", program, with_ui=True)
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        values = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10, check=True).stdout.split()
        hw, hh, ww, wh, lw, lh = map(float, values[:6])
        self.assertEqual((lw, lh), (820, LEGACY_HEIGHT))
        self.assertGreater(hh, lh)
        self.assertEqual(hh, wh)
        self.assertGreaterEqual(ww, hw)
        self.assertEqual(values[6], "true")

    # MARK: scheduled pre-/post-completion persisted reads

    def scheduled_program(self, body):
        return '''
import Foundation
struct Focus {
    enum State { case running, paused, finished }
    var limit: Double?; var state: State; var taskID: Int?
}
struct Segment { var taskID: Int?; var seconds: Double }
struct Snapshot { var focus: Focus?; var focusSegments: [Segment] }
final class File {
    var stored = Snapshot(focus: Focus(limit: 1_020, state: .running, taskID: 7), focusSegments: [])
    func load() throws -> Snapshot { stored }
}
final class Store {
    let file = File()
    var planner: Snapshot { file.stored }
}
nonisolated(unsafe) var log: [String] = []
func require(_ ok: @autoclosure () -> Bool, _ message: String) { log.append("\\(ok() ? "PASS" : "FAIL") \\(message)") }
func completeActiveBlockAtControlledEnd(_ store: Store) -> Bool {
    store.file.stored = Snapshot(
        focus: Focus(limit: 1_020, state: .finished, taskID: 7), focusSegments: [Segment(taskID: 7, seconds: 1_020)])
    return true
}
let scheduledStore = Store()
let scheduled = (id: 7, title: "Prepare the launch checklist")
''' + body + '\nprint(log.joined(separator: "\\n"))\n'

    def scheduled_extract(self):
        body = scheduled_body()
        start = body.index("    let extended = try! scheduledStore.file.load()")
        end = body.index('"scheduled block persists its finished identity and exact 17-minute segment")')
        extract = body[start:end] + '"scheduled block persists its finished identity and exact 17-minute segment")\n'
        return extract.replace('    snapshot(root, "scheduled-time-card-running", into: output)\n', "")

    def test_real_predicates_typecheck_and_read_fresh_post_tick_state(self):
        extract = self.scheduled_extract()
        self.assertEqual(extract.count("try! scheduledStore.file.load()"), 2)
        self.assertLess(extract.index("let extended ="), extract.index("completeActiveBlockAtControlledEnd"))
        self.assertLess(extract.index("completeActiveBlockAtControlledEnd"), extract.index("let persisted ="))
        self.assertIn("scheduledStore.planner.focus?.limit == 1_020 && extended.focus?.limit == 1_020", extract)
        self.assertIn("abs(persisted.focusSegments[0].seconds - 1_020) < 0.001", extract)
        compiled, binary = self.compile("scheduled", self.scheduled_program(extract), with_ui=False)
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        log = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10, check=True).stdout.split("\n")
        self.assertEqual([line.split(" ", 1)[0] for line in log if line], ["PASS"] * 3, log)

    def test_reusing_the_pre_completion_snapshot_would_fail_the_finished_assertion(self):
        stale = self.scheduled_extract().replace("let persisted = try! scheduledStore.file.load()",
                                                 "let persisted = extended")
        compiled, binary = self.compile("scheduled_stale", self.scheduled_program(stale), with_ui=False)
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        log = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10, check=True).stdout
        self.assertIn("FAIL scheduled block persists its finished identity", log)

    def test_original_inline_try_form_does_not_typecheck(self):
        original = self.scheduled_extract().replace(
            "    let extended = try! scheduledStore.file.load()\n", "").replace(
            "extended.focus?.limit == 1_020", "try! scheduledStore.file.load().focus?.limit == 1_020")
        compiled, _ = self.compile("scheduled_original", self.scheduled_program(original), with_ui=False)
        self.assertNotEqual(compiled.returncode, 0)
        self.assertIn("'try!' cannot appear to the right of a non-assignment operator", compiled.stderr)

    def test_exact_limits_actions_and_identities_are_preserved(self):
        body = scheduled_body()
        for kept in ('press(primary, "time-card-primary Start it now")', 'press(addFive, "time-card-add-five")',
                     "scheduledStore.planner.focus?.limit == 720", "persisted.focus?.taskID == scheduled.id",
                     "persisted.focusSegments.count == 1 && persisted.focusSegments[0].taskID == scheduled.id",
                     '"scheduled-focus-completed.json"'):
            self.assertIn(kept, body)


if __name__ == "__main__":
    unittest.main()
