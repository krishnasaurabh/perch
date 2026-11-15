"""Contracts for the standalone Week fixture and explicit Today preview.

The guard is compiled on portable hosts. Sheet presentation and native focus are
still exercised by the macOS matrix and redesign snapshot runner.
"""
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class WorkspacePreviewContractTests(unittest.TestCase):
    def test_legacy_week_sheet_observes_the_presentation_model(self):
        source = (ROOT / "Tests/WorkspaceProbes/WeekBandMatrix.swift").read_text()
        wrapper = source.split("extension AllPageMatrix", 1)[0]
        self.assertRegex(wrapper, r"@EnvironmentObject\s+(?:private\s+)?var model: NotchModel")
        self.assertIn("get: { model.detailsTaskID.map(IDBox.init) }", wrapper)
        self.assertIn("set: { model.detailsTaskID = $0?.id }", wrapper)
        self.assertNotIn("fixture.model.detailsTaskID", wrapper)
        # The caller supplies this exact model, not a second presentation object.
        caller = (ROOT / "scripts/allpage_matrix_probe.swift").read_text()
        start = caller.index("WorkspaceLegacyWeekProbe(fixture: fixture)")
        self.assertIn(".environmentObject(fixture.model)", caller[start:start + 300])

    def test_standalone_today_preview_requests_its_own_capture_focus(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WorkspaceView.swift").read_text()
        launcher = source.split("@MainActor enum WorkspaceShellPreview", 1)[1]
        before_content = launcher.split("let content = WorkspaceView", 1)[0]
        self.assertIn("model.open(page: page, pinned: true)", before_content)
        self.assertRegex(before_content, r"if page == \.home \{ model.captureFocusRequest = UUID\(\) \}")
        self.assertNotIn("app.model.captureFocusRequest", launcher)
        self.assertIn(".environmentObject(model)", launcher)

    def test_capture_readiness_accepts_both_today_targets_only_with_an_editor(self):
        source = (ROOT / "Sources/PerchApp/App/AppDelegate+Preview.swift").read_text()
        capture = source.split("if let text = Self.activePreviewFixture?.captureText", 1)[1]
        match = re.search(r"guard (.*?)\s+else \{", capture, re.DOTALL)
        if match is None:
            self.fail("The preview must guard capture readiness")
        condition = match.group(1)
        program = """import Foundation
final class NSTextView { let isEditable: Bool; init(_ editable: Bool) { isEditable = editable } }
struct Window { let firstResponder: Any? }
func ready(_ target: String, _ window: Window) -> Bool {
    guard """ + condition + """ else { return false }
    return true
}
let editable = Window(firstResponder: NSTextView(true))
for target in ["today", "workspace-today"] {
    precondition(ready(target, editable), "Today capture target rejected: \\(target)")
    precondition(!ready(target, Window(firstResponder: nil)))
    precondition(!ready(target, Window(firstResponder: NSTextView(false))))
    precondition(!ready(target, Window(firstResponder: "not an editor")))
}
for target in ["week", "workspace-week", "workspace-narrow", "settings", "gallery"] {
    precondition(!ready(target, editable), "Non-Today capture target accepted")
}
print("Today capture readiness controls passed")
"""
        swift = shutil.which("swiftc")
        if swift is None:
            self.fail("Swift must be available for the preview guard")
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)
            (path / "main.swift").write_text(program)
            compiled = subprocess.run(
                [swift, "-swift-version", "6", str(path / "main.swift"), "-o", str(path / "guard")],
                capture_output=True, text=True,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(path / "guard")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Today capture readiness controls passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
