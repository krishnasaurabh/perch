"""Compile the production appearance selections, without claiming native rendering."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sources/PerchApp"


class PreviewAppearanceTests(unittest.TestCase):
    def test_shell_and_cards_honor_override_without_changing_defaults(self):
        shell = (APP / "Notch/NotchRootView.swift").read_text()
        card = (APP / "Workspace/Components/CardSurface.swift").read_text()
        preview = (APP / "App/AppDelegate+Preview.swift").read_text()
        preferred = re.search(r"\.preferredColorScheme\(([^\n]+)\)", shell)
        environment = re.search(r"\.environment\(\\.colorScheme, ([^\n]+)\)", shell)
        card_scheme = re.search(r"\.environment\(\\.colorScheme, ([^\n]+)\)", card)
        assert preferred is not None
        assert environment is not None
        assert card_scheme is not None
        marker = "@MainActor\nenum PreviewAppearance"
        helper = marker + preview.split(marker, 1)[1] if marker in preview else ""
        program = r'''
import Foundation

enum ColorScheme: String { case light, dark }
struct Tone { let scheme: ColorScheme }
@MainActor
struct AppDelegate {
    static func previewOption(_ flag: String, in arguments: [String] = CommandLine.arguments) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
}
HELPER
@MainActor
func selections(_ tone: Tone) -> [String] {
    let preference: ColorScheme = PREFERRED
    let environment: ColorScheme = ENVIRONMENT
    let card: ColorScheme = CARD
    return [preference.rawValue, environment.rawValue, card.rawValue]
}
print(String(decoding: try JSONEncoder().encode([
    selections(Tone(scheme: .light)), selections(Tone(scheme: .dark)),
]), as: UTF8.self))
'''.replace("HELPER", helper).replace("PREFERRED", preferred.group(1)).replace(
            "ENVIRONMENT", environment.group(1)).replace("CARD", card_scheme.group(1))
        with tempfile.TemporaryDirectory(prefix="preview-appearance-", dir=os.environ.get("TMPDIR")) as tmp:
            directory = Path(tmp)
            source = directory / "main.swift"
            source.write_text(program)
            for variant in ("release", "DEBUG", "PERCH_TESTING"):
                binary = directory / variant
                command = ["swiftc", "-swift-version", "6", "-O"]
                if variant != "release":
                    command += ["-D", variant]
                build = subprocess.run(command + [str(source), "-o", str(binary)],
                                       capture_output=True, text=True, timeout=60)
                self.assertEqual(build.returncode, 0, build.stderr)
                for appearance in (None, "light", "dark"):
                    args = [] if appearance is None else ["--appearance", appearance]
                    result = subprocess.run([str(binary), *args], check=True, capture_output=True,
                                            text=True, timeout=10)
                    expected = ([["dark", "dark", "light"], ["dark", "dark", "dark"]]
                                if variant == "release" or appearance is None
                                else [[appearance] * 3, [appearance] * 3])
                    with self.subTest(variant=variant, appearance=appearance):
                        self.assertEqual(json.loads(result.stdout), expected)


if __name__ == "__main__":
    unittest.main()
