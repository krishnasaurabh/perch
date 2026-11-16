from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class TimeCardRevisionTests(unittest.TestCase):
    def test_display_schedule_is_connected_to_the_actual_local_clock(self):
        source = (ROOT / "Sources/PerchApp/Workspace/TimeCard.swift").read_text()
        self.assertIn(
            "let interval = TimeCardPresentation.refreshInterval(planner: store.planner, day: store.today)",
            source,
        )
        self.assertIn("LocalClock(running: interval != nil, interval: interval ?? 1)", source)

    def test_step_rendering_uses_only_the_bounded_projection_and_keeps_the_full_count(self):
        source = (ROOT / "Sources/PerchApp/Workspace/TimeCard.swift").read_text()
        self.assertIn("ForEach(progress.fractions.indices", source)
        self.assertNotIn("ForEach(0..<value.totalSteps", source)
        self.assertIn("AnyLayout(VStackLayout(spacing: TimeCardMetrics.smallGap))", source)
        self.assertIn('"%lld of %lld steps", value.completedSteps, value.totalSteps', source)


if __name__ == "__main__":
    unittest.main()
