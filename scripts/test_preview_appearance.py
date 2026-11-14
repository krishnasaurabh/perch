"""Compile real appearance selections and token pairings, not native rendering."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sources/PerchApp"


def contrast(first, second):
    def luminance(rgb):
        channels = [(rgb >> shift & 255) / 255 for shift in (16, 8, 0)]
        linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
                  for c in channels]
        return sum(c * weight for c, weight in zip(linear, (0.2126, 0.7152, 0.0722)))
    a, b = sorted((luminance(first), luminance(second)))
    return (b + 0.05) / (a + 0.05)


class PreviewAppearanceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        shell = (APP / "Notch/NotchRootView.swift").read_text()
        card = (APP / "Workspace/Components/CardSurface.swift").read_text()
        theme = (APP / "Workspace/Theme.swift").read_text()
        preview = (APP / "App/AppDelegate+Preview.swift").read_text()
        preferred = re.search(r"\.preferredColorScheme\(([^\n]+)\)", shell)
        environment = re.search(r"\.environment\(\\.colorScheme, ([^\n]+)\)", shell)
        card_scheme = re.search(r"\.environment\(\\.colorScheme, ([^\n]+)\)", card)
        shell_fill = re.search(r"outline.fill\(([^\n]+)\)", shell)
        assert preferred is not None
        assert environment is not None
        assert card_scheme is not None
        assert shell_fill is not None
        assert ".foregroundStyle(Theme.text)" in card
        # Compile the actual ink resolver, fixed fills and CardTone; only the Apple Color API is shimmed.
        theme_prefix = theme.split("@MainActor enum Theme {", 1)[1].split("    static let tileStrong", 1)[0]
        text_match = re.search(r"    static let text = [^\n]+", theme)
        assert text_match is not None
        text_ink = text_match.group(0)
        theme_source = "@MainActor enum Theme {" + theme_prefix + text_ink + "\n}"
        tone_source = card.split("/// Padded", 1)[0].replace("import SwiftUI", "")
        marker = "@MainActor\nenum PreviewAppearance"
        helper = marker + preview.split(marker, 1)[1]
        program = r'''
import Foundation

enum ColorScheme: String { case light, dark }
struct Color {
    enum Space { case sRGB }
    let light: UInt32
    let dark: UInt32
    init(_ space: Space, red: Double, green: Double, blue: Double) {
        let rgb = UInt32((red * 255).rounded()) << 16
            | UInt32((green * 255).rounded()) << 8 | UInt32((blue * 255).rounded())
        self.init(light: rgb, dark: rgb)
    }
    init(light: UInt32, dark: UInt32) { self.light = light; self.dark = dark }
    static let black = Color(light: 0, dark: 0)
    static func dynamic(light: (UInt32, Double), dark: (UInt32, Double)) -> Color {
        precondition(light.1 == 1 && dark.1 == 1, "Pairing test requires opaque ink")
        return Color(light: light.0, dark: dark.0)
    }
    func rgb(in scheme: ColorScheme) -> UInt32 { scheme == .dark ? dark : light }
}
TOKENS
THEME
TONE
@MainActor
struct AppDelegate {
    static func previewOption(_ flag: String, in arguments: [String] = CommandLine.arguments) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
}
HELPER
struct Pairing: Codable {
    let name, window, local: String
    let foreground, background: UInt32
}
@MainActor
func selections() -> [Pairing] {
    let preference: ColorScheme = PREFERRED
    let environment: ColorScheme = ENVIRONMENT
    var result = [Pairing(name: "shell", window: preference.rawValue, local: environment.rawValue,
                          foreground: Theme.text.rgb(in: environment),
                          background: SHELL_FILL.rgb(in: environment))]
    for (name, tone) in [("tasks", CardTone.tasks), ("timer", .timer), ("tile", .tile)] {
        let card: ColorScheme = CARD
        result.append(Pairing(name: name, window: preference.rawValue, local: card.rawValue,
                              foreground: Theme.text.rgb(in: card), background: tone.fill.rgb(in: card)))
    }
    return result
}
print(String(decoding: try JSONEncoder().encode(selections()), as: UTF8.self))
'''.replace("TOKENS", (ROOT / "Sources/PerchUI/ThemeTokens.swift").read_text()).replace(
            "THEME", theme_source).replace("TONE", tone_source).replace("HELPER", helper).replace(
            "PREFERRED", preferred.group(1)).replace("ENVIRONMENT", environment.group(1)).replace(
            "CARD", card_scheme.group(1)).replace("SHELL_FILL", shell_fill.group(1))
        cls.results = {}
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
                if build.returncode:
                    raise AssertionError(build.stderr)
                for appearance in (None, "light", "dark"):
                    args = [] if appearance is None else ["--appearance", appearance]
                    result = subprocess.run([str(binary), *args], check=True, capture_output=True,
                                            text=True, timeout=10)
                    cls.results[variant, appearance] = json.loads(result.stdout)

    def test_window_honors_override_without_changing_defaults(self):
        for (variant, appearance), rows in self.results.items():
            expected = "dark" if variant == "release" or appearance is None else appearance
            with self.subTest(variant=variant, appearance=appearance):
                self.assertEqual([row["window"] for row in rows], [expected] * 4)

    def test_fixed_surfaces_keep_readable_ink_in_both_appearances(self):
        for (variant, appearance), rows in self.results.items():
            for row in rows:
                with self.subTest(variant=variant, appearance=appearance, surface=row["name"]):
                    self.assertGreaterEqual(contrast(row["foreground"], row["background"]), 4.5)
                    self.assertEqual(row["local"], "light" if row["name"] in ("tasks", "timer") else "dark")

    def test_contrast_check_rejects_opposite_ink_on_each_fixed_surface(self):
        # Negative controls retain the reviewed failure mode even after the local schemes are fixed.
        rows = self.results["release", None]
        opposite = {"light": rows[0]["foreground"], "dark": rows[1]["foreground"]}
        for row in rows:
            with self.subTest(surface=row["name"]):
                self.assertLess(contrast(opposite[row["local"]], row["background"]), 4.5)


if __name__ == "__main__":
    unittest.main()
