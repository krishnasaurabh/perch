"""Compile the probe's actual readiness logic; no AppKit or display is substituted."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "scripts/compact_home_probe.swift"
DRIVER = r'''
import Foundation
struct Sample: Decodable {
    let t: Double
    let owner: String?
    let ended: Double?
}
let samples = try JSONDecoder().decode([Sample].self, from: FileHandle.standardInput.readDataToEndOfFile())
var readiness = CaptureFocusReadiness()
for sample in samples {
    readiness.observe(time: sample.t, editorIdentity: sample.owner, editingEndedAt: sample.ended)
}
let result: [String: Any] = [
    "settled": readiness.settledFocusAt ?? -1,
    "lost": readiness.lostAfterFocus,
]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
'''


def sample(t, owner=None, ended=None):
    return dict(t=t, owner=owner, ended=ended)


class CompactHomeFocusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        swiftc = shutil.which("swiftc")
        if swiftc is None:
            raise RuntimeError("swiftc is required to exercise the real probe readiness logic")
        cls.swiftc = swiftc
        cls.temp = tempfile.TemporaryDirectory(prefix="compact-focus-", dir=os.environ.get("TMPDIR"))
        cls.root = Path(cls.temp.name)
        source = SOURCE.read_text()
        cls.logic = "struct CaptureFocusReadiness {" + source.split(
            "struct CaptureFocusReadiness {", 1)[1].split("\n}\n", 1)[0] + "\n}\n"
        cls.binary = cls.compile(cls.logic, "readiness")

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    @classmethod
    def compile(cls, logic, name):
        source, binary = cls.root / (name + ".swift"), cls.root / name
        source.write_text(logic + DRIVER)
        subprocess.run([cls.swiftc, "-swift-version", "6", str(source), "-o", str(binary)],
                       check=True, capture_output=True, text=True, timeout=60)
        return binary

    def run_samples(self, samples, binary=None):
        result = subprocess.run([str(binary or self.binary)], input=json.dumps(samples),
                                check=True, capture_output=True, text=True, timeout=10)
        return json.loads(result.stdout)

    def test_initial_focus_still_waits_for_minimum_settle(self):
        self.assertEqual(self.run_samples([sample(0.1, "capture"), sample(0.5, "capture")]),
                         dict(settled=-1, lost=False))
        self.assertEqual(self.run_samples([sample(0.1, "capture"), sample(0.81, "capture")]),
                         dict(settled=0.81, lost=False))

    def test_late_native_focus_can_converge_before_deadline(self):
        self.assertEqual(self.run_samples([sample(0.81), sample(2.6, "capture"), sample(2.91, "capture")]),
                         dict(settled=2.91, lost=False))

    def test_brief_incoming_focus_is_not_readiness(self):
        samples = [sample(0.81), sample(1.14, "capture"), sample(1.32),
                   sample(1.53, "capture"), sample(1.84, "capture")]
        self.assertEqual(self.run_samples(samples), dict(settled=1.84, lost=False))

    def test_editing_end_between_positive_samples_restarts_stability(self):
        samples = [sample(0.9, "capture"), sample(1.14, "capture"),
                   sample(1.5, "capture", ended=1.15), sample(1.81, "capture", ended=1.15)]
        self.assertEqual(self.run_samples(samples), dict(settled=1.81, lost=False))

    def test_new_native_owner_restarts_stability(self):
        samples = [sample(0.8, "outgoing"), sample(0.95, "capture"), sample(1.26, "capture")]
        self.assertEqual(self.run_samples(samples), dict(settled=1.26, lost=False))

    def test_missing_editor_never_passes(self):
        self.assertEqual(self.run_samples([sample(0), sample(0.81), sample(3.01)]),
                         dict(settled=-1, lost=False))

    def test_repeated_transients_never_pass(self):
        samples = [sample(i / 10, "capture" if i % 2 else None) for i in range(31)]
        self.assertEqual(self.run_samples(samples), dict(settled=-1, lost=False))

    def test_focus_that_stabilizes_after_deadline_is_rejected(self):
        samples = [sample(0.81), sample(2.9, "capture"), sample(3.21, "capture")]
        self.assertEqual(self.run_samples(samples), dict(settled=-1, lost=False))

    def test_native_focus_loss_after_readiness_is_still_fatal(self):
        samples = [sample(0.1, "capture"), sample(0.81, "capture"), sample(0.9),
                   sample(1.4, "capture"), sample(1.8, "capture")]
        self.assertEqual(self.run_samples(samples), dict(settled=0.81, lost=True))

    def test_same_editor_end_after_readiness_is_still_fatal(self):
        samples = [sample(0.1, "capture"), sample(0.81, "capture"), sample(1.2, "capture", ended=1.0)]
        self.assertEqual(self.run_samples(samples), dict(settled=0.81, lost=True))

    def test_owner_change_after_readiness_is_still_fatal(self):
        samples = [sample(0.1, "capture"), sample(0.81, "capture"), sample(1.2, "other")]
        self.assertEqual(self.run_samples(samples), dict(settled=0.81, lost=True))

    def test_regressions_are_detected_with_compiled_mutations(self):
        cases = [
            ("first-sample", "static let stableInterval = 0.3", "static let stableInterval = 0.0",
             [sample(0.81), sample(1.14, "capture"), sample(1.32),
              sample(1.53, "capture"), sample(1.84, "capture")]),
            ("unbounded", "time <= Self.deadline", "true",
             [sample(2.9, "capture"), sample(3.21, "capture")]),
            ("missed-end", "editingEndedAt >= candidateSince", "false",
             [sample(0.9, "capture"), sample(1.5, "capture", ended=1.15)]),
        ]
        for name, old, new, samples in cases:
            with self.subTest(name=name):
                self.assertEqual(self.logic.count(old), 1)
                mutant = self.compile(self.logic.replace(old, new), name)
                self.assertNotEqual(self.run_samples(samples, mutant), self.run_samples(samples))


if __name__ == "__main__":
    unittest.main()
