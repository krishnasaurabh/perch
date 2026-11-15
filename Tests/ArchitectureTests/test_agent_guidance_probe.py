"""Exercise the real native launch adapter without claiming an AppKit run."""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
TESTS = ROOT / "Tests/PerchAppTests"


class AgentGuidanceProbeTests(unittest.TestCase):
    def launcher(self):
        source = (TESTS / "AgentGuidanceLifetimeTests.swift").read_text()
        match = re.search(r'#"""\n(.*?)\n\s*"""#', source, re.S)
        if match is None:
            raise AssertionError("Missing native launcher")
        return textwrap.dedent(match.group(1))

    def prepare(self, directory):
        tests = directory / "Tests/PerchAppTests"
        tests.mkdir(parents=True)
        for name in ("AgentGuidanceProbeSupport.swift", "AgentGuidanceProbeAssertions.swift"):
            shutil.copy2(TESTS / name, tests / name)
        pane = directory / "Sources/PerchApp/Settings/SettingsAgentsPane.swift"
        pane.parent.mkdir(parents=True)
        shutil.copy2(ROOT / "Sources/PerchApp/Settings/SettingsAgentsPane.swift", pane)
        return pane

    def test_launcher_builds_real_product_and_runs_registered_preview(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            pane = self.prepare(directory)
            original = pane.read_text()
            with patch.object(sys, "argv", ["probe", temporary]), \
                    patch("subprocess.run") as run, \
                    patch("subprocess.check_output", return_value=str(directory / "bin")):
                exec(self.launcher(), {})
            self.assertEqual(run.call_count, 2)
            build, native = run.call_args_list
            self.assertEqual(build.args[0], [
                "swift", "build", "--jobs", "2", "--package-path", temporary,
                "-Xswiftc", "-DAGENT_GUIDANCE_PROBE", "-Xswiftc", "-enable-testing", "--product", "Perch",
            ])
            self.assertEqual(build.kwargs, {"check": True, "timeout": 300})
            self.assertEqual(native.args[0], [str(directory / "bin/Perch"), "--open", "settings/agents-connected"])
            self.assertTrue(native.kwargs["check"])
            self.assertEqual(native.kwargs["timeout"], 120)
            self.assertEqual(native.kwargs["env"]["PERCH_DATA"], str(directory / "isolated-planner.json"))
            self.assertEqual(pane.read_text(), original.replace(
                "AgentsSettings(statuses: $statuses, feedback: feedback)",
                "AgentGuidanceFixture.agents(statuses: $statuses, feedback: feedback, store: store)", 1))
            support = (directory / "Sources/PerchApp/AgentGuidanceProbeSupport.swift").read_text()
            self.assertIn("#if AGENT_GUIDANCE_PROBE", support)
            self.assertIn("func guidanceRequire", support)
            self.assertNotIn("#if AGENT_GUIDANCE_SUPPORT", support)

    def test_launcher_never_masks_build_or_native_failure(self):
        for failed_call in (0, 1):
            with self.subTest(failed_call=failed_call), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                self.prepare(directory)
                calls = []

                def run(command, **options):
                    calls.append(command)
                    if len(calls) - 1 == failed_call:
                        raise subprocess.CalledProcessError(1, command)

                with patch.object(sys, "argv", ["probe", temporary]), \
                        patch("subprocess.run", side_effect=run), \
                        patch("subprocess.check_output", return_value=str(directory / "bin")):
                    with self.assertRaises(subprocess.CalledProcessError):
                        exec(self.launcher(), {})
                self.assertEqual(len(calls), failed_call + 1)

    def test_changed_injection_seam_fails_before_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            pane = self.prepare(Path(temporary))
            pane.write_text(pane.read_text().replace("AgentsSettings(statuses:", "ChangedSettings(statuses:"))
            with patch.object(sys, "argv", ["probe", temporary]), patch("subprocess.run") as run:
                with self.assertRaisesRegex(AssertionError, "injection seam changed"):
                    exec(self.launcher(), {})
                run.assert_not_called()

    def test_real_throwing_assertions_accept_and_reject_values(self):
        swift = shutil.which("swiftc")
        if swift is None:
            raise AssertionError("The local gate requires the configured Swift toolchain")
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            main = directory / "main.swift"
            main.write_text('''
import Foundation
MainActor.assumeIsolated {
    func rejects(_ action: () throws -> Void) {
        do { try action(); fatalError("A false assertion passed") }
        catch is AgentGuidanceFailure {}
        catch { fatalError("Unexpected failure: \\(error)") }
    }
    try! guidanceRequire(true)
    try! guidanceEqual(3, 3)
    try! guidanceEqual(Data([0, 1]), Data([0, 1]))
    try! guidanceNil(Optional<Int>.none)
    try! guidanceNotNil(Optional(1))
    precondition(try! guidanceUnwrap(Optional(3)) == 3)
    rejects { try guidanceRequire(false) }
    rejects { try guidanceEqual(1, 2) }
    rejects { try guidanceEqual(Data([0, 1]), Data([0, 2])) }
    rejects { try guidanceNil(Optional(1)) }
    rejects { try guidanceNotNil(Optional<Int>.none) }
    rejects { _ = try guidanceUnwrap(Optional<Int>.none) }
    print("PASS: assertion positive and negative controls")
}
''')
            binary = directory / "assertions"
            subprocess.run([swift, "-swift-version", "6", str(TESTS / "AgentGuidanceProbeAssertions.swift"),
                            str(main), "-o", str(binary)], check=True, capture_output=True, timeout=60)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.stdout.strip(), "PASS: assertion positive and negative controls")


if __name__ == "__main__":
    unittest.main()
