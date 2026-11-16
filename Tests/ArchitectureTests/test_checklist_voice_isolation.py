"""Compile the extracted voice fixture's actor boundary on each host.

XCTest is real; only the AX functions are typechecking stubs. Actual accessibility
and voice-state assertions remain in the macOS test, not in this portable check.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import call, patch


def compiler_command(swift, source, output):
    command = [swift]
    if sys.platform == "darwin":
        # XCTest lives in Xcode's platform developer frameworks, not the SDK.
        # Standalone swiftc needs the same search roots SwiftPM adds for tests.
        sdk = subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
        ).strip()
        platform = Path(subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-platform-path"], text=True
        ).strip())
        developer = platform / "Developer"
        command += [
            "-sdk", sdk, "-F", str(developer / "Library/Frameworks"),
            "-I", str(developer / "usr/lib"),
        ]
    return command + ["-swift-version", "6", "-emit-sil", str(source), "-o", str(output)]


class VoiceCompilerConfigurationTests(unittest.TestCase):
    def test_macos_uses_selected_sdk_and_developer_frameworks(self):
        sdk = "/Applications/Xcode Test.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
        platform = "/Applications/Xcode Test.app/Contents/Developer/Platforms/MacOSX.platform"
        with patch("sys.platform", "darwin"), patch(
            "subprocess.check_output", side_effect=[sdk + "\n", platform + "\n"]
        ) as discover:
            command = compiler_command("swiftc", Path("fixture.swift"), Path("fixture.sil"))
        self.assertEqual(command, [
            "swiftc", "-sdk", sdk, "-F", platform + "/Developer/Library/Frameworks",
            "-I", platform + "/Developer/usr/lib",
            "-swift-version", "6", "-emit-sil", "fixture.swift", "-o", "fixture.sil",
        ])
        self.assertEqual(discover.call_args_list, [
            call(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True),
            call(["xcrun", "--sdk", "macosx", "--show-sdk-platform-path"], text=True),
        ])

    def test_linux_keeps_toolchain_xctest_without_xcrun(self):
        with patch("sys.platform", "linux"), patch("subprocess.check_output") as discover:
            command = compiler_command("swiftc", Path("fixture.swift"), Path("fixture.sil"))
        self.assertEqual(command, [
            "swiftc", "-swift-version", "6", "-emit-sil", "fixture.swift", "-o", "fixture.sil",
        ])
        discover.assert_not_called()

    def test_sdk_discovery_failure_is_not_silently_skipped(self):
        with patch("sys.platform", "darwin"), patch(
            "subprocess.check_output", side_effect=subprocess.CalledProcessError(1, "xcrun")
        ):
            with self.assertRaises(subprocess.CalledProcessError):
                compiler_command("swiftc", Path("fixture.swift"), Path("fixture.sil"))

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Tests/PerchAppTests/ChecklistVoiceFeedbackTests.swift"


class ChecklistVoiceIsolationTests(unittest.TestCase):
    def program(self, source):
        declaration = re.search(r"private nonisolated(?: static)? func primeAccessibility\(\) async \{", source)
        if declaration is None:
            self.fail("Missing accessibility priming helper")
        start = declaration.start()
        end = source.index("\n        @MainActor private func settle", start)
        helper = source[start:end].strip().replace(
            "AXUIElementCreateApplication(", "fixtureAXUIElementCreateApplication("
        )
        call = re.search(r"await (?:Self\.)?primeAccessibility\(\)", source)
        if call is None:
            self.fail("Missing awaited priming call")
        return """import XCTest
// Only the AX boundary is substituted; actor isolation and task structure are unchanged.
private typealias CFString = String
private typealias CFTypeRef = Any
private struct AXUIElement {}
private let kAXWindowsAttribute = "AXWindows"
private let kAXChildrenAttribute = "AXChildren"
private func fixtureAXUIElementCreateApplication(_ pid: Int32) -> AXUIElement { AXUIElement() }
private func AXUIElementCopyAttributeValue(
    _ element: AXUIElement, _ attribute: CFString, _ value: inout CFTypeRef?
) -> Int32 { 0 }
final class VoiceIsolationFixture: XCTestCase {
    @MainActor func testActorBoundary() async {
        """ + call.group() + """
        _ = self.name
    }
    """ + helper + "\n}\n"

    def typecheck(self, source, imported_symbols=""):
        swift = shutil.which("swiftc")
        if swift is None:
            self.fail("Swift is required to check the native fixture's actor boundary")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "VoiceIsolationFixture.swift"
            path.write_text(imported_symbols + self.program(source))
            return subprocess.run(
                compiler_command(swift, path, path.with_suffix(".sil")),
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

    def test_fixture_does_not_collide_with_platform_ax_function(self):
        # XCTest exposes the real function on macOS. Reproduce its competing
        # overload on every host, without requiring an Apple SDK on Linux.
        imported_symbols = """private struct PlatformAXElement {}
private func AXUIElementCreateApplication(_ pid: Int32) -> PlatformAXElement {
    PlatformAXElement()
}
"""
        source = SOURCE.read_text()
        result = self.typecheck(source, imported_symbols)
        self.assertEqual(result.returncode, 0, result.stderr)
        broken = source.replace("nonisolated static func", "nonisolated func")
        broken = broken.replace("await Self.primeAccessibility()", "await primeAccessibility()")
        result = self.typecheck(broken, imported_symbols)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sending 'self' risks causing data races", result.stderr)

    def test_instance_helper_is_rejected_by_the_same_compiler(self):
        source = SOURCE.read_text().replace("nonisolated static func", "nonisolated func")
        source = source.replace("await Self.primeAccessibility()", "await primeAccessibility()")
        result = self.typecheck(source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sending 'self' risks causing data races", result.stderr)


if __name__ == "__main__":
    unittest.main()
