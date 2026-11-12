#!/usr/bin/env python3
"""Verify localization through the relocated, instrumented macOS executable."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

LOCALIZED = {
    "appEnglish": "1 task", "appPseudo": "⟦2 tàsks ·~⟧",
    "uiEnglish": "1 task", "uiPseudo": "⟦2 tàsks ·~⟧",
}
RAW_KEYS = {
    "appEnglish": "1 tasks", "appPseudo": "2 tasks",
    "uiEnglish": "1 tasks", "uiPseudo": "2 tasks",
}


def run_check(app, data_directory, expected):
    data_directory.mkdir(parents=True, exist_ok=False)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("PERCH_")}
    env["PERCH_DATA"] = str((data_directory / "planner.json").resolve())
    binary = app / "Contents/MacOS/Perch"
    result = subprocess.run([str(binary.resolve()), "--check-localization"], env=env,
                            capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, (app.name, result.returncode, result.stderr)
    values = json.loads(result.stdout)
    assert values == expected, (values, expected)
    assert not list(data_directory.iterdir()), "Localization check opened planner storage"
    print(json.dumps(values, ensure_ascii=False, sort_keys=True))


def check(app, output):
    app, output = Path(app).resolve(), Path(output).resolve()
    assert app.is_dir() and app.suffix == ".app"
    output.mkdir(parents=True, exist_ok=True)
    # The actual packaged binary is checked before testing relocated copies.
    run_check(app, output / "original-data", LOCALIZED)
    for case in ("relocated", "flat", "missing"):
        directory = output / case
        copy = directory / "Perch.app"
        shutil.copytree(app, copy)
        resources = copy / "Contents/Resources"
        for name in ("Perch_PerchApp.bundle", "Perch_PerchUI.bundle"):
            assert not (copy / name).exists(), "Resources must not ship at the app root"
            bundle = resources / name
            assert len(list(bundle.rglob("Localizable.json"))) == 1
            if case != "relocated":
                shutil.rmtree(bundle)
        if case == "missing":
            (resources / "Localizable.json").unlink()
        if case != "relocated":
            # Resource mutation invalidates the copy's signature, not the original's.
            subprocess.run(["codesign", "--force", "--sign", "-", str(copy)],
                           check=True, capture_output=True)
        run_check(copy, directory / "data", RAW_KEYS if case == "missing" else LOCALIZED)
    print("PASS: packaged and relocated catalogs, flat fallback, and missing-resource safety")


if __name__ == "__main__":
    check(*sys.argv[1:])
