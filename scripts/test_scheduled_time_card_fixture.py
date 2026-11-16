"""Exercise the native probe fixture against real planner-day and TimeCard logic."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ScheduledTimeCardFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        swift = shutil.which("swiftc")
        if swift is None:
            raise AssertionError("swiftc is required to exercise the scheduled TimeCard fixture")
        helper = ROOT / "scripts/scheduled_time_card_fixture.swift"
        if not helper.is_file():
            raise AssertionError("The native probe needs its testable wall-clock fixture helper")
        time_card = (ROOT / "Sources/PerchApp/Workspace/TimeCard.swift").read_text()
        presentation = "struct TimeCardPresentation {" + time_card.split(
            "struct TimeCardPresentation {", 1
        )[1].split("/// Long checklists share", 1)[0]
        program = r'''
import Foundation

// Localization is irrelevant to state selection; return the production keys unchanged.
private enum AppL10n {
    static func text(_ key: String) -> String { key }
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: key, arguments: arguments)
    }
}

''' + presentation + helper.read_text() + r'''

struct Row: Encodable {
    let hour: Int
    let state: String
    let primary: String
    let taskMatches: Bool
    let dayMatches: Bool
    let minutes: Int
    let startDelta: Double
}

func row(hour: Int, liveAnchor: Bool) throws -> Row {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let displayNow = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: hour))!
    var engine = PlannerEngine(planner: Planner(), now: { displayNow }, calendar: calendar)
    engine.planner.preferences.resetHour = 4
    let fixture = ScheduledTimeCardProbeFixture(displayNow: displayNow)
    let anchor = liveAnchor
        ? fixture.storeNow
        : engine.today.date(calendar: engine.calendar).addingTimeInterval(12 * 3_600)
    let scheduledStart = liveAnchor ? fixture.scheduledStart : anchor.addingTimeInterval(3_600)
    let scheduled = try engine.addTasks(["Prepare the launch checklist"], on: .day(engine.today), literal: true)[0]
    let index = engine.planner.tasks.firstIndex { $0.id == scheduled.id }!
    engine.planner.tasks[index].startAt = scheduledStart
    engine.planner.tasks[index].minutes = 12
    let value = TimeCardPresentation(planner: engine.planner, day: engine.today, now: displayNow)
    return Row(
        hour: hour,
        state: String(describing: value.state),
        primary: value.primaryTitle,
        taskMatches: value.task?.id == scheduled.id,
        dayMatches: engine.planner.tasks[index].day == engine.today,
        minutes: value.minutes,
        startDelta: scheduledStart.timeIntervalSince(displayNow)
    )
}

let rows = try [3, 10, 14].map { hour in
    ["legacy": try row(hour: hour, liveAnchor: false), "live": try row(hour: hour, liveAnchor: true)]
}
let data = try JSONEncoder().encode(rows)
print(String(decoding: data, as: UTF8.self))
'''
        with tempfile.TemporaryDirectory(prefix="scheduled-time-card-", dir=os.environ.get("TMPDIR")) as temporary:
            directory = Path(temporary)
            main = directory / "main.swift"
            main.write_text(program)
            binary = directory / "scheduled-time-card"
            sources = sorted((ROOT / "Sources/PlannerCore").glob("*.swift"))
            compiled = subprocess.run(
                [swift, "-swift-version", "6", *map(str, sources), str(main), "-o", str(binary)],
                capture_output=True,
                text=True,
                timeout=120,
            )
            if compiled.returncode:
                raise AssertionError(compiled.stderr)
            executed = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10, check=True)
            cls.rows = json.loads(executed.stdout)
            print(json.dumps(cls.rows, indent=2))

    def test_noon_anchor_demonstrates_the_original_before_reset_and_afternoon_failures(self):
        self.assertEqual([row["legacy"]["state"] for row in self.rows], ["empty", "ready", "empty"])
        for row in self.rows:
            with self.subTest(hour=row["legacy"]["hour"], anchor="noon"):
                legacy = row["legacy"]
                if legacy["hour"] == 10:
                    self.assertEqual(legacy["primary"], "Start it now")
                else:
                    self.assertEqual(legacy["primary"], "Set time aside")
                    self.assertFalse(legacy["taskMatches"])
                self.assertTrue(legacy["dayMatches"])

    def test_live_fixture_is_ready_with_the_same_task_and_twelve_minutes_at_every_probe_hour(self):
        for row in self.rows:
            with self.subTest(hour=row["live"]["hour"], anchor="live"):
                live = row["live"]
                self.assertEqual(live["state"], "ready")
                self.assertEqual(live["primary"], "Start it now")
                self.assertTrue(live["taskMatches"])
                self.assertTrue(live["dayMatches"])
                self.assertEqual(live["minutes"], 12)
                self.assertEqual(live["startDelta"], 3_600)

    def test_native_probe_and_wrapper_use_the_shared_live_fixture(self):
        probe = (ROOT / "scripts/focus_entry_probe.swift").read_text().split(
            "func verifyScheduledTimeCard(", 1
        )[1].split("\n}\n", 1)[0]
        self.assertIn("ScheduledTimeCardProbeFixture(displayNow: Date())", probe)
        self.assertIn("now: { fixture.storeNow }", probe)
        self.assertIn("startAt = fixture.scheduledStart", probe)
        self.assertNotIn("addingTimeInterval(12 * 3_600)", probe)
        wrapper = (ROOT / "scripts/check_focus_entry.sh").read_text()
        self.assertIn(
            'cp "$ROOT/scripts/scheduled_time_card_fixture.swift" "$PROBE/Sources/Perch/"', wrapper
        )


if __name__ == "__main__":
    unittest.main()
