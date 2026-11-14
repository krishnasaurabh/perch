"""Portable checks for the snapshot list, batch protocol and fail-closed runner."""
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import zlib
from typing import Any

SCRIPT = Path(__file__).with_name("redesign_shots.sh")


def load_runner():
    source = SCRIPT.read_text().split("# BEGIN PYTHON\n", 1)[1].split("# END PYTHON", 1)[0]
    namespace: dict[str, Any] = {"__name__": "redesign_shots_test"}
    exec(compile(source, str(SCRIPT), "exec"), namespace)
    return namespace


def png(width=4, height=6):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress((b"\0" + b"\xff" * width * 4) * height)) + chunk(b"IEND", b""))


class RedesignShotsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runner = load_runner()

    def test_list_quotes_comments_and_defaults(self):
        shots = self.runner["parse_list"]('# comment\none --scenario "three" --open today # end\ntwo --scenario timer\n')
        self.assertEqual([s["name"] for s in shots], ["one", "two"])
        self.assertEqual(shots[1]["arguments"], ["--scenario", "timer", "--open", "today"])

    def test_bad_lists(self):
        for text in ("", "# empty", "../bad --scenario empty", "a --scenario", "a --scenario ''",
                     "a --snapshot /tmp/out", "a --open today", 'a --scenario "broken',
                     "a --scenario empty --scenario timer", "a --scenario empty\na --scenario three"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.runner["parse_list"](text)

    def test_checked_in_list_is_valid(self):
        shots = self.runner["parse_list"](SCRIPT.with_suffix(".list").read_text())
        self.assertTrue(any("week" in s["arguments"] for s in shots))
        self.assertTrue(any("today" in s["arguments"] for s in shots))

    def fake_run(self, mutation=None, calls=None):
        def run(command, **kwargs):
            if calls is not None:
                calls.append((command, kwargs))
            plan = json.loads(Path(command[command.index("--redesign-shots") + 1]).read_text())
            output = Path(plan["output"])
            entries = []
            for shot in plan["shots"]:
                (output / (shot["name"] + ".png")).write_bytes(png())
                args = shot["arguments"]
                entries.append(dict(name=shot["name"], width=2, height=3, scale=2,
                                    scenario=args[args.index("--scenario") + 1],
                                    target="today", appearance=plan["appearance"],
                                    reduceMotion=plan["reduceMotion"]))
            (output / "result.json").write_text(json.dumps(entries))
            if mutation:
                mutation(output, entries)
            return subprocess.CompletedProcess(command, 0, "", "")
        return run

    def execute(self, run):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            return self.runner["run_shots"](Path("/fake/Perch"), root,
                                             self.runner["parse_list"]("one --scenario three"), run=run)

    def test_one_session_per_appearance_and_motion_mode(self):
        calls = []
        self.assertEqual(self.execute(self.fake_run(calls=calls)), 4)
        self.assertEqual(len(calls), 4)
        self.assertTrue(all(c[1]["env"]["TZ"] == "UTC" for c in calls))
        self.assertEqual(sum("--reduce-motion" in c[0] for c in calls), 2)
        self.assertTrue(all("PERCH_DATA" in c[1]["env"] for c in calls))

    def test_missing_image_and_stale_output_fail(self):
        with self.assertRaisesRegex(ValueError, "image"):
            self.execute(self.fake_run(lambda out, _: (out / "one.png").unlink()))

    def test_corrupt_image_fails(self):
        with self.assertRaisesRegex(ValueError, "PNG"):
            self.execute(self.fake_run(lambda out, _: (out / "one.png").write_bytes(b"not png")))

    def test_wrong_scale_fails(self):
        with self.assertRaisesRegex(ValueError, "2x"):
            self.execute(self.fake_run(lambda out, _: (out / "one.png").write_bytes(png(2, 3))))

    def test_missing_or_duplicate_receipt_fails(self):
        for entries in ([], [dict(name="one"), dict(name="one")]):
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                self.execute(self.fake_run(lambda out, _: (out / "result.json").write_text(json.dumps(entries))))

    def test_wrong_target_appearance_or_motion_fails(self):
        for field, value in (("target", "settings"), ("scenario", "timer"),
                             ("appearance", "wrong"), ("reduceMotion", "false")):
            def mutate(out, entries):
                entries[0][field] = value
                (out / "result.json").write_text(json.dumps(entries))
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.execute(self.fake_run(mutate))

    def test_missing_receipt_fails(self):
        with self.assertRaisesRegex(ValueError, "receipt"):
            self.execute(self.fake_run(lambda out, _: (out / "result.json").unlink()))

    def test_app_diagnostic_is_in_failure_and_saved_log(self):
        diagnostic = "Perch preview: Snapshot appearance did not apply."
        def failed(command, **kwargs):
            return subprocess.CompletedProcess(command, 64, "starting\n", diagnostic + "\n")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaisesRegex(RuntimeError, diagnostic):
                self.runner["run_shots"](Path("/fake/Perch"), root,
                                         self.runner["parse_list"]("one --scenario three"), run=failed)
            self.assertEqual((root / "light.log").read_text(), "starting\n" + diagnostic + "\n")

    def test_timeout_preserves_partial_output(self):
        def timeout(command, **kwargs):
            raise subprocess.TimeoutExpired(command, 1, output=b"opening today\n", stderr=b"still laying out\n")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaisesRegex(RuntimeError, "timed out"):
                self.runner["run_shots"](Path("/fake/Perch"), root,
                                         self.runner["parse_list"]("one --scenario three"), run=timeout)
            self.assertEqual((root / "light.log").read_text(), "opening today\nstill laying out\n")

    def test_crash_and_timeout_fail(self):
        def crash(command, **kwargs):
            return subprocess.CompletedProcess(command, -6, "", "crashed")
        def timeout(command, **kwargs):
            raise subprocess.TimeoutExpired(command, 1)
        for run in (crash, timeout):
            with self.subTest(run=run), self.assertRaises(RuntimeError):
                self.execute(run)


if __name__ == "__main__":
    unittest.main()
