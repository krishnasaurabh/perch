#!/usr/bin/env python3
"""Check the distribution executable, not the instrumented probe bundle."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

TEST_FLAGS = ["--demo", "--demo-clips", "--scenario", "--preview-open", "--page", "--snapshot",
              "--dump-layout", "--dump-activity", "--motion-script", "--motion-policy", "--motion-snapshots",
              "--check-localization"]
TEST_MARKERS = TEST_FLAGS + ["MotionScript", "PlannerPreview", "PERCH_SCREENSHOT_FOLDER",
                              "PERCH_MOTION_MISSING_CONTROL", "PERCH_MOTION_AX_WAKE"]


def assert_no_hooks(binary):
    content = Path(binary).read_bytes()
    # Debug line tables can retain the name of an empty, conditionally compiled source file.
    # Check executable symbols for types/functions; raw bytes for runtime environment selectors.
    symbols = subprocess.check_output(["nm", "-j", str(binary)], text=True)
    for marker in ["MotionScript", "PlannerPreview", "motionPolicyOverride", "seedPreview", "seedDemo", "layoutDump", "AppLocalizationCheck"]:
        assert marker not in symbols, f"Release contains diagnostic symbol: {marker}"
    for marker in TEST_FLAGS + ["PERCH_SCREENSHOT_FOLDER", "PERCH_MOTION_MISSING_CONTROL", "PERCH_MOTION_AX_WAKE"]:
        assert marker.encode() not in content, f"Release contains test hook: {marker}"


def check(binary, output):
    binary = str(Path(binary).resolve())
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    assert_no_hooks(binary)
    data = output / "planner.json"
    data.write_text(json.dumps({"preferences": {"welcomeCompleted": True,
        "catchCopies": False, "catchScreenshots": False, "remindersSync": False, "ringOnPhone": False}}))
    original = data.read_bytes()
    env = dict(os.environ, PERCH_DATA=str(data))
    for flag in TEST_FLAGS + ["--unknown"]:
        result = subprocess.run([binary, flag, str(output / "unexpected")], env=env,
                                capture_output=True, timeout=10)
        assert result.returncode == 64, (flag, result.returncode)
        assert data.read_bytes() == original, f"Rejected flag modified storage: {flag}"
        assert not (output / "unexpected").exists()
    # Environment-only diagnostics are ignored in Release. No permission requests or live data.
    env.update(PERCH_SCREENSHOT_FOLDER=str(output / "unused"),
               PERCH_MOTION_MISSING_CONTROL="Open workspace", PERCH_MOTION_AX_WAKE="inproc")
    with (output / "launch.log").open("wb") as log:
        process = subprocess.Popen([binary], env=env, stdout=log, stderr=log)
        try:
            time.sleep(5)
            assert process.poll() is None, f"Release app exited: {process.returncode}"
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=10)
    planner = json.loads(data.read_text())
    assert not planner.get("tasks"), "Release seeded synthetic tasks"
    assert not planner.get("focus"), "Release seeded a synthetic timer"
    assert not (output / "unused").exists()
    print("PASS: Release excludes diagnostic flags/symbols, rejects test arguments before I/O, and survives a 5s launch")


if __name__ == "__main__":
    check(*sys.argv[1:])
