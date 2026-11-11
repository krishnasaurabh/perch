"""Portable failure controls for the native workspace probe, not UI execution."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class WorkspaceProbeTests(unittest.TestCase):
    def test_assertions_reject_missing_focus_targets_and_ring_pixels(self):
        source = (ROOT / "scripts/workspace_navigation_probe.swift").read_text()
        helpers = source.split("private func failure(", 1)[1].split("let application =", 1)[0]
        program = """
import Foundation
private enum WorkspaceNavigationError: Error {
    case assertion(String, String, UInt)
}
private func failure(""" + helpers + """
private func rejects(_ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw WorkspaceNavigationError.assertion("Negative control passed", #fileID, #line)
}
try require(true)
try requireFalse(false)
try requireEqual("selected", "selected")
try requireEqual(Double(2), Double(2.5), accuracy: 1)
try requireEqual(CGFloat(2), CGFloat(2.5), accuracy: 1)
try requireAtLeast(CGFloat(28), CGFloat(28))
try requireAtLeast(CGFloat(28), Double(28))
try requireEqual(CGFloat(2), Double(2), accuracy: 1)
try requireGreater(CGFloat(1), CGFloat(0))
try requireNil(Optional<Int>.none)
try requireEqual(try unwrap(Optional(1)), 1)
try rejects { try require(false, "Missing native focus") }
try rejects { try requireFalse(true, "Focus stolen") }
try rejects { try requireEqual("Not selected", "Selected") }
try rejects { try requireEqual(Double(0), Double(2), accuracy: 1) }
try rejects { try requireEqual(CGFloat(0), CGFloat(2), accuracy: 1) }
try rejects { try requireEqual(Double.nan, Double(2), accuracy: 1) }
try rejects { try requireAtLeast(CGFloat(26), CGFloat(28)) }
try rejects { try requireGreater(CGFloat(0), CGFloat(0)) }
try rejects { try requireNil(Optional(1)) }
try rejects { _ = try unwrap(Optional<Int>.none) }
print("Workspace assertion positive and negative controls passed")
"""
        with tempfile.TemporaryDirectory() as directory:
            main = pathlib.Path(directory) / "main.swift"
            main.write_text(program)
            swift = shutil.which("swiftc")
            if swift is None:
                self.fail("Swift must be available to verify the native assertion helpers")
            binary = pathlib.Path(directory) / "assertion-controls"
            subprocess.run([swift, str(main), "-o", str(binary)], check=True, capture_output=True, text=True)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn("positive and negative controls passed", result.stdout)

    def test_runner_rejects_non_macos_before_building(self):
        with tempfile.TemporaryDirectory() as directory:
            uname = pathlib.Path(directory) / "uname"
            uname.write_text("#!/bin/sh\nprintf '%s\\n' Linux\n")
            uname.chmod(0o755)
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/check_workspace_navigation.sh"), directory],
                env=dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"]),
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("requires macOS", result.stderr)
            self.assertFalse((pathlib.Path(directory) / "planner.json").exists())


if __name__ == "__main__":
    unittest.main()
