"""Replay the live composer's draft publication across checklist/timeline integration.

The view method and value models are production source; only the SwiftUI-owned
capture state and read-only store properties are hosted by a portable adapter.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CARD = ROOT / "Sources/PerchApp/Workspace/TasksCard.swift"


class ChecklistTimelineIntegrationTests(unittest.TestCase):
    def test_live_composer_preserves_multiline_schedule_and_step_isolation(self):
        source = CARD.read_text()
        method = "    private func updateDraft() {" + source.split(
            "    private func updateDraft() {", 1)[1].split("    private func changeIndent(", 1)[0]
        models = "\n".join(
            (ROOT / path).read_text().replace("import PlannerCore", "")
            for path in ("Sources/PerchUI/TodayTaskNavigation.swift",
                         "Sources/PerchUI/YourDayTimeline.swift",
                         "Sources/PerchUI/TodayHomeState.swift"))
        program = "import Foundation\n" + models + r'''
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
struct Store {
    let today: DayKey
    let capture: TaskCapture
    let prefs: Preferences
}
@MainActor final class Composer {
    var capture = TodayTaskCapture()
    var parsed: CapturedTask?
    var day: DayRef
    let store: Store
    let homeState: TodayHomeState? = TodayHomeState()
    private var text: String { capture.text }
    init(store: Store) { self.store = store; day = .day(store.today) }
    func refresh() { updateDraft() }
''' + method + r'''
}
require(TaskParserLanguage.current == .english, "The replay must use the production English language path")
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 0)!
let today = DayKey("2026-11-13")
let now = today.date(calendar: calendar).addingTimeInterval(9 * 3600)
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
let file = PlannerFile(url: directory.appendingPathComponent("planner.json"),
                       preferences: MemoryPlannerPreferences())
var planner = Planner()
planner.preferences.resetHour = 0
planner.preferences.defaultFocusMinutes = 35
try file.save(planner)
let before = try Data(contentsOf: file.url)
let parser = TaskCapture(now: now, resetHour: 0, calendar: calendar)
let composer = Composer(store: Store(today: today, capture: parser, prefs: planner.preferences))
let text = "Read today at 10am\nWrite today at 1pm for 20 min"
composer.capture.text = text
composer.refresh()
require(composer.parsed == nil, "Multiline input must not publish misleading single-task chips")
let preview = composer.homeState?.captureDraft
require(preview != nil, "Multiline capture must still publish the first scheduled timeline block")
require(preview?.minutes == 20, "The scheduled line must keep its own duration")
require(preview?.startTime == parser.parse("Write today at 1pm for 20 min", language: .english).startAt,
        "Time and duration from different lines must not combine")
require(composer.capture.indent(parentID: UUID()), "Enter step mode through its real transition")
composer.refresh()
require(composer.parsed == nil, "Step entry must not expose task chips")
require(composer.homeState?.captureDraft == nil, "A step cannot schedule a task block")
require(composer.capture.outdent(), "Leave step mode through its real transition")
composer.refresh()
require(composer.homeState?.captureDraft == preview, "Outdenting restores the same scheduled-line preview")
composer.capture.text = "Review today at 2pm for 35 min"
composer.refresh()
require(composer.parsed?.startAt == parser.parse(composer.capture.text, language: .english).startAt,
        "Single-line parsed chips still follow the capture parser")
require(composer.homeState?.captureDraft?.minutes == 35, "Single-line preview retains its own duration")
composer.capture.text = "Reminder today at 2pm"
composer.refresh()
require(composer.parsed?.remindAt != nil, "A time without duration remains a reminder")
require(composer.homeState?.captureDraft == nil, "A reminder alone must not schedule a block")
composer.capture.text = "Review tomorrow at 2pm for 20 min"
composer.refresh()
require(composer.homeState?.captureDraft == nil, "Tomorrow's task must not preview on Today")
composer.capture.text = text
composer.day = .inbox
composer.refresh()
require(composer.parsed == nil, "Inbox capture must clear Today chip state")
require(composer.homeState?.captureDraft == nil, "Inbox capture must clear the Today schedule draft")
composer.day = .day(today)
composer.refresh()
require(composer.homeState?.captureDraft == preview, "Returning to Today restores the schedule draft")
composer.capture.text = ""
composer.refresh()
require(composer.homeState?.captureDraft == nil, "Clearing the editor clears its schedule draft")
let afterPreview = try Data(contentsOf: file.url)
require(afterPreview == before, "Draft publication must not write planner data")
let pipeline = PlannerCommandPipeline(file: file, clock: ClosurePlannerClock { now }, calendar: calendar)
let result = try pipeline.perform(origin: .user) { commands in
    try TodayTaskCapture.submit(text, parentID: nil, on: .day(today), commands: commands, language: .english)
}
let added = result.value
require(added.count == 2, "Multiline submission must create exactly two tasks")
require(added[0].startAt == nil, "The first line must not borrow the second line's duration")
let scheduled = added.first { $0.startAt != nil }
require(scheduled?.startAt == preview?.startTime, "Preview start must match the real submitted task")
require(scheduled?.minutes == preview?.minutes, "Preview duration must match the real submitted task")
print("Checklist timeline: multiline publication, step isolation, defaults and real submission verified")
'''
        swift = shutil.which("swiftc")
        self.assertIsNotNone(swift, "Swift is required for composer integration regressions")
        with tempfile.TemporaryDirectory() as directory:
            main = Path(directory) / "main.swift"
            main.write_text(program)
            binary = Path(directory) / "composer"
            sources = sorted((ROOT / "Sources/PlannerCore").glob("*.swift"))
            compiled = subprocess.run(
                [swift, "-swift-version", "6", *map(str, sources), str(main), "-o", str(binary)],
                capture_output=True, text=True, timeout=180)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            env = dict(os.environ, LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8", TZ="UTC")
            result = subprocess.run([str(binary)], env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("defaults and real submission verified", result.stdout)

    def test_live_owners_keep_both_drag_payloads_and_one_draft_writer(self):
        source = CARD.read_text()
        composer = source.split("struct TaskComposer:", 1)[1].split("struct ChecklistCaptureField:", 1)[0]
        self.assertIn(".onChange(of: capture) { _, _ in updateDraft() }", composer)
        self.assertIn(".onChange(of: day) { _, _ in updateDraft() }", composer)
        appearance = composer.split(".onAppear {", 1)[1].split(".onChange(of: capture)", 1)[0]
        self.assertIn("updateDraft()", appearance)
        self.assertIn(".onDisappear { homeState?.captureDraft = nil }", composer)
        self.assertNotIn("YourDayCaptureBridge(", composer)
        add = composer.split("    func add() {", 1)[1].split("    private func dictate()", 1)[0]
        self.assertIn('capture.text = ""', add)
        self.assertIn("homeState?.captureDraft = nil", add)
        row = (ROOT / "Sources/PerchApp/Workspace/TaskRow.swift").read_text()
        self.assertIn(".onDrag { ChecklistTaskDrag.provider(for: task.id) }", row)
        self.assertIn("JSONEncoder().encode(TaskDragItem(taskID: id))", row)
        self.assertIn("NSItemProvider(object: id.uuidString as NSString)", row)
        self.assertEqual(row.count(".onDrag {"), 1)
        self.assertNotIn(".onDrag {", source)
        timeline = (ROOT / "Sources/PerchApp/Workspace/YourDayCard.swift").read_text()
        self.assertIn(".dropDestination(for: TaskDragItem.self)", timeline)


if __name__ == "__main__":
    unittest.main()
