"""Snapshot refresh must include device-only closed-state preferences."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ClosedPreviewRefreshTests(unittest.TestCase):
    def test_batch_refresh_is_not_gated_by_planner_file_metadata(self):
        source = (ROOT / "Sources/PerchApp/App/AppDelegate+Preview.swift").read_text()
        batch = source.split("private func runPreviewShot(at index: Int)", 1)[1]
        batch = batch.split("private func capturePreviewShot", 1)[0]
        self.assertIn("_ = store.performMutation(origin: .background) { _ in () }", batch)
        self.assertNotIn("store.reloadFromDisk(external: false)", batch)
        self.assertIn("guard store.planner == fixture.planner else", batch)


if __name__ == "__main__":
    unittest.main()
