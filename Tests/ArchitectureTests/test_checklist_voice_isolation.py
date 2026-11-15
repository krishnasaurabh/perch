"""Compile the voice fixture's actor boundary without an Apple SDK.

The AX functions below are typechecking stubs only. Actual accessibility and
voice-state assertions remain in the macOS test, not in this portable check.
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Tests/PerchAppTests/ChecklistVoiceFeedbackTests.swift"


class ChecklistVoiceIsolationTests(unittest.TestCase):
    def program(self, source):
        declaration = re.search(r"private nonisolated(?: static)? func primeAccessibility\(\) async \{", source)
        if declaration is None:
            self.fail("Missing accessibility priming helper")
        start = declaration.start()
        end = source.index("\n        @MainActor private func settle", start)
        helper = source[start:end].strip()
        call = re.search(r"await (?:Self\.)?primeAccessibility\(\)", source)
        if call is None:
            self.fail("Missing awaited priming call")
        return """import XCTest
// Only the Foundation-free AX boundary is substituted; the helper is unchanged.
private typealias CFString = String
private typealias CFTypeRef = Any
private struct AXUIElement {}
private let kAXWindowsAttribute = "AXWindows"
private let kAXChildrenAttribute = "AXChildren"
private func AXUIElementCreateApplication(_ pid: Int32) -> AXUIElement { AXUIElement() }
private func AXUIElementCopyAttributeValue(
    _ element: AXUIElement, _ attribute: CFString, _ value: inout CFTypeRef?
) -> Int32 { 0 }
final class VoiceIsolationFixture: XCTestCase {
    @MainActor func testActorBoundary() async {
        """ + call.group() + """
        _ = self.name
    }
    """ + helper + "\n}\n"

    def typecheck(self, source):
        swift = shutil.which("swiftc")
        if swift is None:
            self.fail("Swift is required to check the native fixture's actor boundary")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "VoiceIsolationFixture.swift"
            path.write_text(self.program(source))
            return subprocess.run(
                [swift, "-swift-version", "6", "-emit-sil", str(path), "-o", str(path.with_suffix(".sil"))],
                capture_output=True, text=True, timeout=60,
            )

    def test_off_main_priming_does_not_send_the_test_case(self):
        source = SOURCE.read_text()
        result = self.typecheck(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("await Self.primeAccessibility()", source)
        self.assertIn("private nonisolated static func primeAccessibility()", source)
        self.assertIn("await Task.detached {", source)
        self.assertLess(source.index("await Self.primeAccessibility()"), source.index("rootView: VoiceFixture"))

    def test_instance_helper_is_rejected_by_the_same_compiler(self):
        source = SOURCE.read_text().replace("nonisolated static func", "nonisolated func")
        source = source.replace("await Self.primeAccessibility()", "await primeAccessibility()")
        result = self.typecheck(source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sending 'self' risks causing data races", result.stderr)


if __name__ == "__main__":
    unittest.main()
