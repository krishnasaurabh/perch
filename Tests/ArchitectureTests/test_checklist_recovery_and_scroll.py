"""Execute production predicates and the scroll-proxy seam without AppKit.

The native XCTest runs the same scroll request assertions with SwiftUI.UnitPoint;
this portable replay substitutes only that value type, not navigation or domain rules.
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CARD = ROOT / "Sources/PerchApp/Workspace/TasksCard.swift"


class ChecklistRecoveryAndScrollTests(unittest.TestCase):
    def compile_and_run(self, program, extra_sources=()):
        swift = shutil.which("swiftc")
        if swift is None:
            self.fail("Swift is required for checklist regressions")
        framework_flags = []
        xcrun = shutil.which("xcrun")
        if xcrun:
            platform = subprocess.run(
                [xcrun, "--show-sdk-platform-path"],
                capture_output=True, text=True, timeout=30)
            if platform.returncode == 0:
                frameworks = str(Path(platform.stdout.strip()) / "Developer/Library/Frameworks")
                framework_flags = ["-F", frameworks, "-Xlinker", "-rpath", "-Xlinker", frameworks]
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            main = folder / "main.swift"
            main.write_text(program)
            sources = sorted((ROOT / "Sources/PlannerCore").glob("*.swift"))
            binary = folder / "checklist"
            compiled = subprocess.run(
                [swift, "-swift-version", "6", *map(str, sources),
                 *map(str, extra_sources), str(main), "-o", str(binary), *framework_flags],
                capture_output=True, text=True, timeout=180)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout

    def test_dismissed_task_remains_recoverable_through_the_rendered_predicates(self):
        source = CARD.read_text()
        footer = re.search(r"if ([^\n]+) \{\s*footer\.fixedSize", source).group(1)
        button = re.search(r'if ([^\n]+) \{\s*Button\("Bring over"\)', source).group(1)
        review = source.split("private struct OverdueReview:", 1)[1]
        candidates = re.search(r"let tasks = ([^\n]+)", review).group(1)
        action = re.search(
            r'PerchButton\("Bring all to today", kind: \.soft\) \{\s*resolve \{ (.*?) \}',
            review).group(1).replace("$0", "commands")
        program = r'''import Foundation
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
struct Store { let engine: PlannerEngine; let canUndo: Bool }
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 0)!
let now = Date(timeIntervalSince1970: 1_800_000_000)
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
let file = PlannerFile(url: directory.appendingPathComponent("planner.json"),
                       preferences: MemoryPlannerPreferences())
let pipeline = PlannerCommandPipeline(file: file, clock: ClosurePlannerClock { now }, calendar: calendar)
let today = DayKey(now, calendar: calendar)
let original = PlanTask(title: "Unfinished yesterday", day: today.adding(days: -1, calendar: calendar),
                        steps: [Subtask(title: "Keep the original step")])
var planner = Planner()
planner.preferences.carryMode = .never
planner.tasks = [original]
try file.save(planner)
try pipeline.perform(origin: .user) { try $0.dismissOverdue([original.id]) }
let dismissed = try file.load()
require(dismissed.dismissedOverdue == [original.id], "Dismissal must persist through the real command path")
let engine = PlannerEngine(planner: dismissed, now: { now }, calendar: calendar)
require(engine.overdue().isEmpty, "Dismissed-only overdue must stay empty")
require(engine.bringOverCandidates().map(\.id) == [original.id], "Recovery candidates must ignore dismissal")
var guarded = engine
require(guarded.carryForward([original.id], to: today).isEmpty, "Ordinary carry must still reject dismissed ids")
// Undo is deliberately unavailable: the footer must survive persisted dismissals after a restart too.
let store = Store(engine: engine, canUndo: false)
require(FOOTER, "Dismissed task must keep the footer visible")
require(BUTTON, "Dismissed task must keep Bring over visible")
let tasks = CANDIDATES
require(tasks.map(\.id) == [original.id], "Review must list the promised recovery candidate")
try pipeline.perform(origin: .user) { commands in ACTION }
let recovered = try file.load()
let copies = recovered.tasks.filter { $0.day == today && !$0.done }
require(copies.count == 1, "Recovery must create exactly one open copy today")
require(copies[0].carriedTaskID == original.id, "Copy must retain its source identity")
require(copies[0].steps.map(\.title) == original.steps.map(\.title), "Recovery must preserve step titles")
require(copies[0].steps.map(\.done) == original.steps.map(\.done), "Recovery must preserve step completion")
require(Set(copies[0].steps.map(\.id)).isDisjoint(with: original.steps.map(\.id)), "Copied steps need fresh identities")
require(recovered.tasks.first { $0.id == original.id } == original, "Original history record must be preserved")
require(recovered.dismissedOverdue == [original.id], "Carried history stays dismissed to prevent another prompt")
let after = PlannerEngine(planner: recovered, now: { now }, calendar: calendar)
require(after.overdue().isEmpty, "Overdue must remain empty after recovery")
try pipeline.perform(origin: .user) { _ = try $0.bringOver() }
let repeated = try file.load()
require(repeated.tasks.filter { $0.day == today && !$0.done }.count == 1, "Recovery must be idempotent")
print("Dismissed recovery: persisted, footer visible, button visible, one copy, original preserved, overdue empty")
'''
        # Each expression/action is copied verbatim from the production view, not restated in this test.
        for token, value in (("FOOTER", footer), ("BUTTON", button),
                             ("CANDIDATES", candidates), ("ACTION", action)):
            program = program.replace(token, value)
        self.assertIn("one copy, original preserved, overdue empty", self.compile_and_run(program))

    def test_step_selection_calls_the_scroll_proxy_with_the_selected_identity(self):
        source = CARD.read_text()
        observer = re.search(
            r"\.onChange\(of: selectedStepID\) \{ _, id in\s*([^\n]+)", source)
        if observer is None:
            self.fail("Step selection needs its own scroll observer")
        self.assertEqual(observer.group(1).strip(),
                         "ChecklistStepScroll.reveal(id) { scroll.scrollTo($0, anchor: $1) }")
        row = (ROOT / "Sources/PerchApp/Workspace/TaskRow.swift").read_text()
        self.assertRegex(row, r"keyboardFocusable: false, surface: surface\s*\)\s*\.id\(step.id\)")
        self.assertEqual(source.count(".focused($focus, equals: .checklist)"), 1)
        helper = source.split("enum ChecklistStepScroll {", 1)[1].split("\n}\n", 1)[0]
        navigation = (ROOT / "Sources/PerchUI/TodayTaskNavigation.swift").read_text()
        navigation = navigation.replace("import PlannerCore", "")
        native = (ROOT / "Tests/PerchAppTests/ChecklistStepScrollTests.swift").read_text()
        native = re.sub(r"^(?:@testable )?import (?:PerchApp|PerchUI|SwiftUI)\n", "", native, flags=re.M)
        # Only the SwiftUI point value is substituted. Execute the exact native XCTest body.
        program = '''import Foundation
import XCTest
struct UnitPoint: Equatable { static let center = UnitPoint() }
enum ChecklistStepScroll {\n''' + helper + "\n}\n" + navigation + "\n" + native + '''
XCTMain([testCase([("testArrowSelectionRequestsCenteredScrollBeyondViewport",
    ChecklistStepScrollTests.testArrowSelectionRequestsCenteredScrollBeyondViewport)])])
'''
        output = self.compile_and_run(program, [ROOT / "Sources/PerchUI/DesignTokens.swift"])
        self.assertIn("Executed 1 test, with 0 failures", output)


if __name__ == "__main__":
    unittest.main()
