"""Exercise Welcome's actual completion policy without claiming native rendering."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def completion(source):
    start = source.index("    static func complete(")
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


class WelcomeRecoveryNavigationTests(unittest.TestCase):
    def test_completion_keeps_navigation_available_after_a_failed_preference_write(self):
        source = (ROOT / "Sources/PerchApp/Settings/WelcomeView.swift").read_text()
        program = '''import Foundation
struct Preferences { var welcomeCompleted = false }
enum Update { case welcomeCompleted(Bool) }
struct Engine {
    mutating func updatePreference(_ update: Update) throws {}
}
final class PlannerStore {
    var prefs = Preferences()
    var writable = true
    var attempts = 0
    func apply(_ update: (inout Engine) throws -> Void) {
        attempts += 1
        var engine = Engine()
        try! update(&engine)
        if writable { prefs.welcomeCompleted = true }
    }
}
final class Window {
    var closes = 0
    func close() { closes += 1 }
}
@MainActor enum WindowHost {
    static var windows: [String: Window] = [:]
}
@MainActor struct WelcomeView {
''' + completion(source) + '''
    static func verify() {
        for writable in [false, true] {
            for alreadyComplete in [false, true] {
                for openToday in [false, true] {
                    let store = PlannerStore()
                    store.writable = writable
                    store.prefs.welcomeCompleted = alreadyComplete
                    let window = Window()
                    WindowHost.windows["welcome"] = window
                    var opened = 0
                    complete(store: store, openToday: openToday) { opened += 1 }
                    precondition(opened == (openToday ? 1 : 0), "Welcome blocked Today navigation")
                    precondition(window.closes == (openToday ? 0 : 1), "Welcome blocked its quiet exit")
                    precondition(store.attempts == (alreadyComplete ? 0 : 1))
                    precondition(store.prefs.welcomeCompleted == (alreadyComplete || writable))
                }
            }
        }
        print("Welcome completion: 8 navigation and persistence cases passed")
    }
}
WelcomeView.verify()
'''
        compiler = shutil.which("swiftc")
        if compiler is None:
            self.fail("Swift is required for the actual completion policy")
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder) / "main.swift"
            binary = Path(folder) / "welcome-completion"
            main.write_text(program)
            built = subprocess.run([compiler, "-swift-version", "6", str(main), "-o", str(binary)],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("8 navigation and persistence cases passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
