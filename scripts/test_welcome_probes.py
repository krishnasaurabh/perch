"""Welcome probe contracts and executable metric controls, not native UI evidence."""
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
REASONS = (
    "To show your meetings in Your day",
    "For reminders when Perch is closed",
    "Only if you choose to dictate",
)


class WelcomeProbeTests(unittest.TestCase):
    def test_integration_uses_current_copy_and_the_production_window_size(self):
        source = (ROOT / "scripts/integration_probe.swift").read_text()
        welcome = source.split("func checkWelcomeMatrix(", 1)[1].split("func checkDetailsMatrix(", 1)[0]
        self.assertEqual(welcome.count("size: WelcomeView.windowSize"), 2)
        self.assertEqual(welcome.count('contains("a calmer way through a busy day")'), 2)
        self.assertIn('contains("nothing to allow yet")', welcome)
        self.assertIn('contains("your tasks stay on this mac")', welcome)
        self.assertNotIn('contains("close at hand")', welcome)
        self.assertIn('PermissionPanel(services: fixture.services, features: [.notifications])', welcome)
        self.assertIn('permissionText.contains("requires the installed perch app")', welcome)
        for check in (
            'done.value == 1', 'fixture.store.planner.tasks == tasksBefore',
            'store.lastError != nil', 'doneAfterError.value == 1', 'try Data(contentsOf: url) == corrupt',
        ):
            self.assertIn(check, welcome)

    def test_allpage_keeps_informational_welcome_and_live_settings_separate(self):
        source = (ROOT / "scripts/allpage_matrix_probe.swift").read_text()
        welcome = source.split("func welcomeStates()", 1)[1].split("func welcomeSettingsPermissionStates(", 1)[0]
        settings = source.split("func welcomeSettingsPermissionStates(", 1)[1].split("func detailsStates()", 1)[0]
        self.assertIn("size: WelcomeView.windowSize", welcome)
        for text in REASONS + (
            "A calmer way through a busy day", "Write it down", "Give it time", "Park the rest",
            "Nothing to allow yet", "Your tasks stay on this Mac.", "Start with three things",
            "Perch asks only when you first use something.",
        ):
            self.assertIn('"' + text + '"', welcome)
        self.assertIn('!mxTree(root).contains { mxIdentifier($0)?.hasPrefix("permission-row.") == true }', welcome)
        self.assertIn('PermissionState.allCases.allSatisfy { !mxHas(root, $0.title) }', welcome)
        self.assertNotIn("SettingsPermissionAccess(", welcome)
        self.assertNotIn("PermissionPanel(", welcome)
        self.assertIn('try await mxKey(window, 36, "\\r")', welcome)
        self.assertIn('opened == 1', welcome)
        self.assertIn('try await welcomeSettingsPermissionStates(fixture)', welcome)
        for check in (
            'PermissionPanel(services: fixture.services)',
            'for feature in PermissionFeature.allCases', 'let reading = await access.read(feature)',
            'mxPermissionRow(root, feature: feature.rawValue)', 'mxHas(row, reading.state.title)',
            'allowedRows == allowedStates',
        ):
            self.assertIn(check, settings)
        self.assertNotIn('.request(', settings)

    def test_theme_keeps_settings_status_growth_and_measures_welcome_reasons(self):
        source = (ROOT / "scripts/theme_probe.swift").read_text()
        self.assertIn('"welcome", WelcomeView.windowSize, nil,', source)
        self.assertIn('for name in ["settings-calendar"]', source)
        self.assertIn('let (base, big) = statusGrowth[name] ?? (0, 0)', source)
        self.assertIn('base > 0 && big >= base * 1.4', source)
        self.assertIn('"welcome_reason_heights": reasonHeights', source)
        for reason in REASONS:
            self.assertIn('"' + reason + '"', source)

    def test_actual_reason_measurement_rejects_missing_zero_duplicate_and_fixed_frames(self):
        source = (ROOT / "scripts/theme_probe.swift").read_text()
        reasons = re.search(r'    let welcomeReasons = \[.*?\n    \]\.map \{ AppL10n.text\(\$0\) \}', source, re.S)
        self.assertIsNotNone(reasons)
        assert reasons is not None
        sampling = source.split('            if page.name == "welcome" {', 1)[1].split('            Measured.rows.append([', 1)[0]
        sampling = 'if page.name == "welcome" {' + sampling
        checks = source.split('    for reason in welcomeReasons {\n        let (base, big)', 1)[1].split('    let payload:', 1)[0]
        checks = 'for reason in welcomeReasons {\n        let (base, big)' + checks
        program = '''import Foundation
struct AppL10n { static func text(_ text: String) -> String { text } }
struct Page { var name = "welcome" }
struct State { let name: String }
enum Measured {
    static var failures: [String] = []
    static func check(_ value: Bool, _ label: String) { if !value { failures.append(label) } }
}
''' + reasons.group(0) + '''
func measure(_ mutation: String) -> Bool {
    Measured.failures = []
    var welcomeReasonGrowth: [String: (Double, Double)] = [:]
    let page = Page()
    for name in ["standard", "enlarged-type", "increased-contrast", "enlarged-increased"] {
        let state = State(name: name)
        let label = "welcome [\\(name)]"
        let enlarged = name.hasPrefix("enlarged")
        var frames = welcomeReasons.map { ($0, CGRect(x: 0, y: 0, width: 180, height: enlarged ? 40 : 20)) }
        if mutation == "missing" { frames.removeFirst() }
        if mutation == "zero" { frames[0].1.size.height = 0 }
        if mutation == "duplicate" { frames.append(frames[0]) }
        if mutation == "unrelated" { frames[0].0 = "Allowed" }
        if mutation == "fixed" { frames[0].1.size.height = 20 }
        // Match pageTextFrames: zero-size nodes never become measurable text.
        frames = frames.filter { $0.1.width > 0 && $0.1.height > 0 }
        var reasonHeights: [String: Double] = [:]
''' + sampling + '''
    }
''' + checks + '''
    return Measured.failures.isEmpty
}
precondition(measure("valid"))
for mutation in ["missing", "zero", "duplicate", "unrelated", "fixed"] {
    precondition(!measure(mutation), mutation)
}
print("Welcome reason metric: valid passed, five corrupt fixtures rejected")
'''
        swift = shutil.which("swiftc")
        self.assertIsNotNone(swift, "Swift is required to execute measurement controls")
        assert swift is not None
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "main.swift"
            binary = pathlib.Path(directory) / "reason-metrics"
            path.write_text(program)
            built = subprocess.run([swift, str(path), "-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            ran = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(ran.returncode, 0, ran.stderr)
            self.assertIn("five corrupt fixtures rejected", ran.stdout)


if __name__ == "__main__":
    unittest.main()
