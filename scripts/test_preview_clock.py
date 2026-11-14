"""Compile actual presentation expressions with Core fixtures; not native UI execution."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PreviewClockTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        swift = shutil.which("swiftc")
        if swift is None:
            raise AssertionError("swiftc is required to exercise presentation clocks")
        workspace = ROOT / "Sources/PerchApp/Workspace"
        header = (workspace / "WorkspaceView.swift").read_text()
        row = (workspace / "TaskRow.swift").read_text()
        # Compile the expressions the real views use, rather than restating the fix.
        header_date = re.search(r"Text\(([^\n]+), format: \.dateTime\.weekday", header)
        reminder = re.search(r"\.foregroundStyle\(([^\n]+) \? Theme\.danger : Theme\.secondary\)", row)
        if header_date is None or reminder is None:
            raise AssertionError("Update the presentation probe when the view expressions change")
        program = r'''
import Foundation

// Match the store's existing engine/clock boundary without importing AppKit.
private final class Clock {
    var now: Date
    init(_ now: Date) { self.now = now }
}
private struct Store {
    let planner: Planner
    let clock: Clock
    var engine: PlannerEngine {
        PlannerEngine(planner: planner, now: { clock.now }, calendar: PlannerPreviewScenarios.calendar)
    }
}
private func displayedDate(_ store: Store) -> Date { HEADER_DATE }
private func isOverdue(_ task: PlanTask, _ store: Store) -> Bool {
    guard let r = task.remindAt else { return false }
    return REMINDER
}
let fixture = try PlannerPreviewScenarios.make("today-before")
private let clock = Clock(fixture.now)
private let store = Store(planner: fixture.planner, clock: clock)
let formatter = DateFormatter()
formatter.calendar = PlannerPreviewScenarios.calendar
formatter.locale = Locale(identifier: "en_US_POSIX")
formatter.timeZone = PlannerPreviewScenarios.calendar.timeZone
formatter.dateFormat = "yyyy-MM-dd"
let tasks = fixture.planner.tasks.filter { $0.remindAt != nil }
var samples: [[String: Any]] = []
for offset in [0.0, -86400.0, 86400.0] {
    clock.now = fixture.now.addingTimeInterval(offset)
    samples.append([
        "expectedDate": formatter.string(from: clock.now),
        "displayedDate": formatter.string(from: displayedDate(store)),
        "overdue": tasks.map { isOverdue($0, store) },
    ])
}
// Check exact reminder boundaries and completed tasks with the same predicate.
let first = tasks[0]
clock.now = first.remindAt!
let atBoundary = isOverdue(first, store)
clock.now = clock.now.addingTimeInterval(1)
let afterBoundary = isOverdue(first, store)
var done = first
done.done = true
let completed = isOverdue(done, store)
let result: [String: Any] = [
    "samples": samples, "reminderCount": tasks.count,
    "atBoundary": atBoundary, "afterBoundary": afterBoundary, "completed": completed,
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
'''.replace("HEADER_DATE", header_date.group(1)).replace("REMINDER", reminder.group(1))
        with tempfile.TemporaryDirectory(prefix="preview-clock-", dir=os.environ.get("TMPDIR")) as temporary:
            directory = Path(temporary)
            main = directory / "main.swift"
            main.write_text(program)
            binary = directory / "preview-clock"
            sources = sorted((ROOT / "Sources/PlannerCore").glob("*.swift"))
            compiled = subprocess.run(
                [swift, "-swift-version", "6", "-D", "DEBUG", *map(str, sources), str(main), "-o", str(binary)],
                capture_output=True, text=True, timeout=120,
            )
            if compiled.returncode:
                raise AssertionError(compiled.stderr)
            executed = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10, check=True)
            cls.result = json.loads(executed.stdout)

    def test_header_follows_fixture_clock_and_clock_changes(self):
        samples = self.result["samples"]
        self.assertEqual(len(samples), 3)
        self.assertEqual(samples[0]["expectedDate"], "2026-11-13")
        for sample in samples:
            with self.subTest(date=sample["expectedDate"]):
                self.assertEqual(sample["displayedDate"], sample["expectedDate"])

    def test_reminders_follow_fixture_clock_and_preserve_boundary_and_done_rules(self):
        self.assertEqual(self.result["reminderCount"], 4)
        before, previous_day, next_day = self.result["samples"]
        self.assertEqual(before["overdue"], [False] * 4)
        self.assertEqual(previous_day["overdue"], [False] * 4)
        self.assertEqual(next_day["overdue"], [True] * 4)
        self.assertFalse(self.result["atBoundary"])
        self.assertTrue(self.result["afterBoundary"])
        self.assertFalse(self.result["completed"])


if __name__ == "__main__":
    unittest.main()
