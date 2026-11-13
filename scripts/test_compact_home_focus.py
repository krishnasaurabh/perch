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
let deadline = CommandLine.arguments.contains("--dense-repeat")
    ? CaptureFocusReadiness.denseRepeatDeadline : CaptureFocusReadiness.deadline
var readiness = CaptureFocusReadiness(traceDeadline: deadline)
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

    def run_samples(self, samples, binary=None, *, dense=False):
        command = [str(binary or self.binary)] + (["--dense-repeat"] if dense else [])
        result = subprocess.run(command, input=json.dumps(samples),
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

    def test_dense_late_focus_has_time_to_stabilize(self):
        samples = [sample(0.81), sample(2.7, "capture"), sample(3.01, "capture")]
        self.assertEqual(self.run_samples(samples, dense=True), dict(settled=3.01, lost=False))

    def test_dense_late_owner_change_restarts_stability(self):
        samples = [sample(2.6, "outgoing"), sample(2.85, "capture"),
                   sample(3.0, "capture"), sample(3.16, "capture")]
        self.assertEqual(self.run_samples(samples, dense=True), dict(settled=3.16, lost=False))

    def test_dense_late_reacquisition_has_time_to_stabilize(self):
        samples = [sample(0.001), sample(2.084, "capture"), sample(2.569, ended=2.085),
                   sample(3.105, "capture", ended=2.085), sample(3.415, "capture", ended=2.085)]
        self.assertEqual(self.run_samples(samples, dense=True), dict(settled=3.415, lost=False))

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

    def test_dense_window_does_not_change_single_open_deadline(self):
        samples = [sample(2.7, "capture"), sample(3.01, "capture")]
        self.assertEqual(self.run_samples(samples), dict(settled=-1, lost=False))
        self.assertEqual(self.run_samples(samples, dense=True), dict(settled=3.01, lost=False))

    def test_dense_initial_focus_still_waits_for_minimum_settle(self):
        self.assertEqual(self.run_samples([sample(0.1, "capture"), sample(0.5, "capture")], dense=True),
                         dict(settled=-1, lost=False))
        self.assertEqual(self.run_samples([sample(0.1, "capture"), sample(0.81, "capture")], dense=True),
                         dict(settled=0.81, lost=False))

    def test_dense_missing_transient_and_churning_focus_never_pass(self):
        cases = [
            [sample(0), sample(0.81), sample(4.01)],
            [sample(i / 10, "capture" if i % 2 else None) for i in range(42)],
            [sample(i / 10, "first" if i % 2 else "second") for i in range(42)],
            [sample(2.7, "capture"), sample(2.9), sample(4.01)],
        ]
        for samples in cases:
            with self.subTest(samples=samples):
                self.assertEqual(self.run_samples(samples, dense=True), dict(settled=-1, lost=False))

    def test_dense_focus_still_requires_a_full_stable_interval(self):
        samples = [sample(2.7, "capture"), sample(2.99, "capture")]
        self.assertEqual(self.run_samples(samples, dense=True), dict(settled=-1, lost=False))
        self.assertEqual(self.run_samples(samples + [sample(3.01, "capture")], dense=True),
                         dict(settled=3.01, lost=False))

    def test_dense_focus_that_stabilizes_after_deadline_is_rejected(self):
        for samples in ([sample(3.8, "capture"), sample(4.11, "capture")],
                        [sample(2.7, "first"), sample(2.9, "second"),
                         sample(3.2, "third"), sample(3.8, "capture"), sample(4.11, "capture")]):
            with self.subTest(samples=samples):
                self.assertEqual(self.run_samples(samples, dense=True), dict(settled=-1, lost=False))

    def test_dense_focus_loss_end_and_owner_change_after_readiness_are_fatal(self):
        prefix = [sample(2.7, "capture"), sample(3.01, "capture")]
        for suffix in ([sample(3.2), sample(3.6, "capture")],
                       [sample(3.4, "capture", ended=3.2)],
                       [sample(3.4, "other")]):
            with self.subTest(suffix=suffix):
                self.assertEqual(self.run_samples(prefix + suffix, dense=True), dict(settled=3.01, lost=True))

    def test_dense_deadline_is_wired_to_repeat_observation_only(self):
        source = SOURCE.read_text()
        self.assertIn("static let denseRepeatDeadline = 4.0", self.logic)
        self.assertIn("static let deadline = 3.0", self.logic)
        self.assertEqual(source.count("deadline: CaptureFocusReadiness.denseRepeatDeadline"), 1)
        self.assertIn('label: "dense-repeat-\\(iteration)", full: true,', source)
        self.assertIn("if (t >= CaptureFocusReadiness.deadline && t >= readiness.traceDeadline)", source)
        self.assertIn("CaptureFocusReadiness(traceDeadline: deadline)", source)
        self.assertIn("for iteration in 1...20", source)

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
            ("unbounded", "time <= traceDeadline", "true",
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
