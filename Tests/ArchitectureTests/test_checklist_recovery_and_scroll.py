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
        strips = (ROOT / "Sources/PerchApp/Notch/NotchStrips.swift").read_text()
        footer_match = re.search(r"else if ([^\n]+) \{\s*// The shared footer", strips)
        assert footer_match is not None, "Shared Undo footer must retain a visibility predicate"
        footer = footer_match.group(1)
        self.assertIn('footer.modifier(NotchUndoFooter(', source)
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
let reviewOverdue = true
let buttonVisible: Bool
if BUTTON { buttonVisible = true } else { buttonVisible = false }
require(buttonVisible, "Dismissed task must keep Bring over visible")
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
        # Replay every native XCTest condition with require, without a standalone XCTest dependency.
        program = '''import Foundation
struct UnitPoint: Equatable { static let center = UnitPoint() }
enum ChecklistStepScroll {\n''' + helper + "\n}\n" + navigation + r'''
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
let ids = (0..<15).map { _ in UUID() }
let rowHeight = DesignTokens.Size.stepRowHeight.value
let viewportHeight = 300.0
require(Double(ids.count) * rowHeight > viewportHeight, "The steps must exceed the viewport height")
var selected = ids[0]
var requests: [(UUID, UnitPoint)] = []
let record: (UUID, UnitPoint) -> Void = { requests.append(($0, $1)) }
ChecklistStepScroll.reveal(selected, using: record)
for index in 1..<ids.count {
    let candidate = TodayTaskNavigation.neighbor(in: ids, from: selected, offset: 1)
    require(candidate != nil, "a neighbor exists")
    selected = candidate!
    ChecklistStepScroll.reveal(selected, using: record)
    require(requests.last?.0 == ids[index], "The selected step must be the scroll target")
    require(requests.last?.1 == UnitPoint.center, "The selected step must be centered")
}
// The last selected row starts below the capped, initially visible window.
require(Double(ids.count - 1) * rowHeight > viewportHeight, "The last selected row must start below the viewport")
require(requests.count == ids.count, "Every selection must request exactly one scroll")
require(requests.map(\.0) == ids, "Scroll targets must follow every selected step in order")
let candidate = TodayTaskNavigation.neighbor(in: ids, from: selected, offset: -1)
require(candidate != nil, "a neighbor exists")
selected = candidate!
ChecklistStepScroll.reveal(selected, using: record)
require(requests.last?.0 == ids[13], "Backward selection must scroll to the previous step")
require(requests.last?.1 == UnitPoint.center, "The previous step must be centered")
ChecklistStepScroll.reveal(nil, using: record)
require(requests.count == ids.count + 1, "Leaving the step cursor must not scroll")
print("ChecklistStepScroll: centered reveals verified for 15 rows")
'''
        output = self.compile_and_run(program, [ROOT / "Sources/PerchUI/DesignTokens.swift"])
        self.assertIn("ChecklistStepScroll: centered reveals verified for 15 rows", output)

    def test_display_order_changes_reveal_the_same_selection_only_while_checklist_focused(self):
        source = CARD.read_text()
        viewport = source.split("ScrollViewReader { scroll in", 1)[1].split(
            ".frame(minHeight: 0, maxHeight:", 1)[0]
        match = re.search(r"\.onChange\(of: ids\) \{ _, remaining in\n(.*?)\n                    \}",
                          viewport, re.S)
        # An absent order observer is the original bug: no request when the ID survives.
        observer = match.group(1) if match else ""
        navigation = (ROOT / "Sources/PerchUI/TodayTaskNavigation.swift").read_text().replace(
            "import PlannerCore", "")
        program = r'''import Foundation
struct UnitPoint: Equatable { static let center = UnitPoint() }
enum TodayFocus { case checklist, capture }
struct HomeState { var selectedTaskID: UUID? }
final class Scroll {
    var requests: [(UUID, UnitPoint)] = []
    func scrollTo(_ id: UUID, anchor: UnitPoint) { requests.append((id, anchor)) }
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
''' + navigation + r'''
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
let file = PlannerFile(url: directory.appendingPathComponent("planner.json"),
                       preferences: MemoryPlannerPreferences())
let now = Date(timeIntervalSince1970: 1_800_000_000)
let pipeline = PlannerCommandPipeline(file: file, clock: ClosurePlannerClock { now })
let tasks = try pipeline.perform(origin: .user) {
    try $0.addTasks((1...24).map { "Inspect item \($0)" }, on: .day($0.today))
}.value
let selected = tasks[0].id
var homeState = HomeState(selectedTaskID: selected)
var selectedStepID: UUID?
var focus = TodayFocus.checklist
var foldSelected = false
let scroll = Scroll()
func displayed() throws -> [PlanTask] {
    TodayTaskNavigation.ordered(try file.load().tasks, currentID: nil)
}
@MainActor func changed(_ remaining: [UUID]) {
OBSERVER
}
@MainActor func expectReveal(_ id: UUID, _ phase: String) {
    require(scroll.requests.count == 1 && scroll.requests.last?.0 == id,
            "\(phase): moved selection must issue one reveal for its unchanged identity")
    require(scroll.requests.last?.1 == .center, "\(phase): reveal must center the selected row")
    require(homeState.selectedTaskID == selected, "\(phase): reveal must not change selection")
    require(focus == .checklist, "\(phase): reveal must not change keyboard ownership")
    scroll.requests = []
}
let initial = try displayed()
require(initial.first?.id == selected, "fixture begins with the first task selected")
try pipeline.perform(origin: .user) { try $0.complete(selected) }
let completed = try displayed()
require(completed.last?.id == selected && completed.last?.done == true, "real completion moves row 0 to row 23")
require(TodayTaskNavigation.visible(completed, expanded: false, selectedID: selected).count == 24,
        "the folded list must render the moved selection")
require(Double(completed.count - 1) * 38 > 300, "the completed row starts below the 300pt viewport")
changed(completed.map(\.id))
expectReveal(selected, "completion")
try pipeline.perform(origin: .user) { try $0.reopen(selected) }
let reopened = try displayed()
require(reopened.first?.id == selected && reopened.first?.done == false, "next action reopens the same task")
changed(reopened.map(\.id))
expectReveal(selected, "reopen")
for offset in [1, 1, -1] {
    let before = try displayed()
    let move = TodayTaskNavigation.reorder(before, currentID: nil, selectedID: selected, offset: offset)!
    try pipeline.perform(origin: .user) { try $0.reorder(selected, before: move.beforeID) }
    let after = try displayed()
    require(before.map(\.id) != after.map(\.id), "keyboard reorder changes displayed position")
    changed(after.map(\.id))
    expectReveal(selected, "reorder")
}
// A selected step keeps its own cursor when its parent changes displayed position.
try pipeline.perform(origin: .user) { commands in
    try commands.updateTask(selected) { $0.steps = (1...15).map { Subtask(title: "Step \($0)") } }
}
selectedStepID = try file.load().tasks.first { $0.id == selected }!.steps.last!.id
let move = TodayTaskNavigation.reorder(try displayed(), currentID: nil, selectedID: selected, offset: 1)!
try pipeline.perform(origin: .user) { try $0.reorder(selected, before: move.beforeID) }
changed(try displayed().map(\.id))
expectReveal(selectedStepID!, "step parent reorder")
// A text entry update must not scroll the list or take the capture field's focus.
focus = .capture
try pipeline.perform(origin: .user) { try $0.complete(selected) }
changed(try displayed().map(\.id))
require(scroll.requests.isEmpty && focus == .capture && homeState.selectedTaskID == selected,
        "capture focus suppresses the order reveal without changing selection")
focus = .checklist; foldSelected = true
changed(try displayed().map(\.id))
require(scroll.requests.isEmpty, "the fold cursor must not reveal a task instead")
foldSelected = false
changed(try displayed().filter { $0.id != selected }.map(\.id))
require(scroll.requests.isEmpty, "a removed selection must be left to the removal observer")
homeState.selectedTaskID = nil
changed(try displayed().map(\.id))
require(scroll.requests.isEmpty, "no selection must not produce a reveal")
print("Display-order reveal: completion, reopen, reorder, step cursor and focus controls passed")
'''
        output = self.compile_and_run(program.replace("OBSERVER", observer))
        self.assertIn("step cursor and focus controls passed", output)

    def test_native_dense_reveal_regression_uses_keyboard_geometry_and_persistence(self):
        probe = (ROOT / "scripts/focus_entry_probe.swift").read_text()
        self.assertIn("await verifyDenseChecklistReveal(", probe)
        dense = probe.split("func verifyDenseChecklistReveal(", 1)[1].split(
            "func verifyCaptureUndoSubmission(", 1)[0]
        for marker in ("1...24", "height <= 300", "viewport.contains(row)",
                       'key(" ", code: 49', "sameTaskContent", "store.file.load()",
                       "homeState.selectedTaskID == target.id", "isFocused(checklist)",
                       'modifiers: [.option]', '"step-complete-\\(stepID)"',
                       "sameTaskContent(try! store.file.load().tasks, expectedStepOrder)",
                       "window.firstResponder === editor", "captureScrollOrigin",
                       "dense completion keeps the selected row visible",
                       "dense reopen keeps the same task visible"):
            self.assertIn(marker, dense)


if __name__ == "__main__":
    unittest.main()
