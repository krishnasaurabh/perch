from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class TimeCardContractTests(unittest.TestCase):
    def test_time_card_consumes_engine_without_a_second_timer(self):
        source = (ROOT / "Sources/PerchApp/Workspace/TimeCard.swift").read_text()
        for action in (".pauseTimer", ".resumeTimer", ".extendTimer(5)", ".startTimer"):
            self.assertIn(action, source)
        for independent_clock in ("Timer.publish", "scheduledTimer", "Task.sleep", "asyncAfter"):
            self.assertNotIn(independent_clock, source)
        self.assertIn("LocalClock(running:", source)
        self.assertIn("TodayHomeState.self", source)
        self.assertIn("time-card-ring", source)
        self.assertIn(".accessibilityLabel(value.ringLabel)", source)

    def test_all_states_are_registered_for_snapshot_matrix(self):
        shots = (ROOT / "scripts/redesign_shots.list").read_text()
        for state, scenario in (("ready", "today-before"), ("running", "today-running"),
                                ("paused", "today-paused"), ("empty", "today-empty")):
            self.assertIn(f"time-card-{state} --scenario {scenario} --open workspace-today", shots)

    def test_time_ring_and_primary_use_motion_and_surface_tokens(self):
        card = (ROOT / "Sources/PerchApp/Workspace/TimeCard.swift").read_text()
        ring = card
        self.assertIn("Card(.blush)", card)
        self.assertIn(".designMotion(.pop, value: value.state)", card)
        self.assertRegex(card, r"motionPolicy.reduceMotion\s*\? .identity")
        self.assertIn(".designMotion(.time, value: fraction)", ring)
        self.assertIn("Theme.brandFill", ring)
        self.assertIn("Theme.ink2", ring)
        self.assertNotIn(".opacity(0.", ring)
        self.assertNotIn("ViewThatFits", card)
        self.assertNotIn(".system(size:", card)

    def test_completion_signal_stays_with_the_existing_store(self):
        store = (ROOT / "Sources/PerchApp/App/PlannerStore.swift").read_text()
        controller = (ROOT / "Sources/PerchApp/Notch/NotchController.swift").read_text()
        services = (ROOT / "Sources/PerchApp/Services/Services.swift").read_text()
        self.assertIn("if change.value.flag { self.focusFinished?() }", store)
        self.assertIn("store.focusFinished =", controller)
        self.assertIn(".focusDone(", services)


if __name__ == "__main__":
    unittest.main()
