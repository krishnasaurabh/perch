"""Portable packaging tests; Apple tools are deterministic local fakes."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "scripts" / "bundle.sh"
WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
EPOCH = 1_767_823_200
ICON_FILES = (
    "icon_16x16.png", "icon_32x32.png", "icon_128x128.png",
    "icon_256x256.png", "icon_512x512.png", "icon_512x512@2x.png",
)


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "repo"
        (self.root / "scripts").mkdir(parents=True)
        shutil.copy2(BUNDLE, self.root / "scripts" / "bundle.sh")
        shutil.copytree(ROOT / "Resources", self.root / "Resources")
        self.bin = self.root / "fake-bin"
        self.bin.mkdir()
        self.log = self.root / "calls.jsonl"
        self.build_bin = self.root / "build-bin"
        self._common()
        self._tools()
        self.env = dict(
            os.environ,
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
            PLISTBUDDY=str(self.bin / "PlistBuddy"),
            FAKE_LOG=str(self.log),
            FAKE_BIN_OUTPUT=str(self.build_bin),
            SOURCE_DATE_EPOCH=str(EPOCH),
            FAKE_GATEKEEPER="reject",
        )
        for key in ("SIGN_ID", "SIGN_KEYCHAIN", "NOTARIZE", "ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH"):
            self.env.pop(key, None)

    def _write(self, name, text):
        path = self.bin / name
        path.write_text("#!/usr/bin/env python3\n" + text)
        path.chmod(0o755)

    def _common(self):
        (self.bin / "fake_common.py").write_text('''import json, os

def record(tool, args, **extra):
    row = {"tool": tool, "args": args, **extra}
    with open(os.environ["FAKE_LOG"], "a") as stream:
        stream.write(json.dumps(row) + "\\n")
''')

    def _tools(self):
        self._write("swift", '''import os, pathlib, sys
from fake_common import record
record("swift", sys.argv[1:])
out = pathlib.Path(os.environ["FAKE_BIN_OUTPUT"])
if "--show-bin-path" in sys.argv:
    print(out)
else:
    out.mkdir(parents=True, exist_ok=True)
    binary = out / "Perch"
    binary.write_bytes(b"synthetic-perch-binary")
    binary.chmod(0o755)
''')
        self._write("PlistBuddy", '''import plistlib, sys
from fake_common import record
record("PlistBuddy", sys.argv[1:])
command, path = sys.argv[2], sys.argv[3]
with open(path, "rb") as stream:
    value = plistlib.load(stream)
verb, key, *rest = command.split(" ", 2)
if verb == "Print":
    print(value[key])
elif verb == "Set":
    value[key] = rest[0]
    with open(path, "wb") as stream:
        plistlib.dump(value, stream)
else:
    raise SystemExit(2)
''')
        self._write("iconutil", '''import os, pathlib, sys
from fake_common import record
record("iconutil", sys.argv[1:])
out = pathlib.Path(sys.argv[sys.argv.index("-o") + 1])
out.mkdir(parents=True)
missing = os.environ.get("FAKE_MISSING_ICON")
for name in ''' + repr(ICON_FILES) + ''':
    if name != missing:
        (out / name).write_bytes(b"synthetic-icon")
''')
        self._write("codesign", '''import pathlib, sys
from fake_common import record
record("codesign", sys.argv[1:])
if "--verify" not in sys.argv:
    app = pathlib.Path(sys.argv[-1])
    signature = app / "Contents" / "_CodeSignature"
    signature.mkdir(parents=True, exist_ok=True)
    (signature / "CodeResources").write_bytes(b"synthetic-code-resources")
''')
        self._write("spctl", '''import os, sys
from fake_common import record
record("spctl", sys.argv[1:])
if os.environ.get("FAKE_GATEKEEPER") != "accept":
    print("rejected", file=sys.stderr)
    raise SystemExit(1)
print("accepted")
''')
        self._write("hdiutil", '''import hashlib, json, os, pathlib, stat, sys
from fake_common import record
if sys.argv[1] == "verify":
    record("hdiutil", sys.argv[1:])
    raise SystemExit(0)
stage = pathlib.Path(sys.argv[sys.argv.index("-srcfolder") + 1])
out = pathlib.Path(sys.argv[-1])
rows = []
for path in sorted(stage.rglob("*")):
    info = path.lstat()
    row = {"path": str(path.relative_to(stage)), "mode": oct(stat.S_IMODE(info.st_mode)),
           "mtime": int(info.st_mtime)}
    if path.is_symlink():
        row["target"] = os.readlink(path)
    elif path.is_file():
        row["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    rows.append(row)
record("hdiutil", sys.argv[1:], stage=rows)
out.write_bytes(json.dumps(rows, sort_keys=True).encode())
''')
        self._write("ditto", '''import pathlib, shutil, sys
from fake_common import record
record("ditto", sys.argv[1:])
shutil.copytree(sys.argv[1], sys.argv[2], symlinks=True)
''')
        self._write("shasum", '''import hashlib, pathlib, sys
for name in sys.argv[3:]:
    print(hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest() + "  " + name)
''')
        self._write("lipo", '''import sys
from fake_common import record
record("lipo", sys.argv[1:])
print("Architectures in the fat file: Perch are: arm64 x86_64")
''')
        self._write("xcrun", '''import json, sys
from fake_common import record
record("xcrun", sys.argv[1:])
if sys.argv[1:3] == ["notarytool", "submit"]:
    print(json.dumps({"status": "Accepted", "id": "synthetic-submission"}))
''')

    def run_bundle(self, **changes):
        env = dict(self.env)
        for key, value in changes.items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = str(value)
        return subprocess.run(
            ["bash", str(self.root / "scripts" / "bundle.sh")],
            cwd=self.root, env=env, text=True, capture_output=True, timeout=30,
        )

    def calls(self, tool=None):
        if not self.log.exists():
            return []
        rows = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [row for row in rows if tool is None or row["tool"] == tool]

    def plist(self, app):
        with (app / "Contents" / "Info.plist").open("rb") as stream:
            return plistlib.load(stream)

    def test_adhoc_release_is_reproducible_and_explicitly_not_notarized(self):
        first = self.run_bundle()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn("ad-hoc", first.stdout)
        self.assertIn("not notarized", first.stdout)
        app = self.root / "dist" / "Perch.app"
        metadata = self.plist(app)
        self.assertEqual(metadata["CFBundleIdentifier"], "app.perch.mac")
        self.assertEqual(metadata["CFBundleShortVersionString"], "1.1.1")
        self.assertEqual(metadata["CFBundleVersion"], "3")
        self.assertEqual(metadata["CFBundleIconFile"], "AppIcon")
        self.assertEqual((app / "Contents" / "Resources" / "AppIcon.icns").read_bytes(),
                         (self.root / "Resources" / "AppIcon.icns").read_bytes())
        self.assertEqual(stat.S_IMODE((app / "Contents" / "MacOS" / "Perch").stat().st_mode), 0o755)
        self.assertEqual(stat.S_IMODE((app / "Contents" / "Info.plist").stat().st_mode), 0o644)
        sign = self.calls("codesign")[0]["args"]
        self.assertIn("--options", sign)
        self.assertIn("runtime", sign)
        self.assertIn("--entitlements", sign)
        self.assertIn("--timestamp=none", sign)
        self.assertEqual(sign[sign.index("-s") + 1], "-")
        self.assertTrue(any("--verify" in row["args"] and "--strict" in row["args"]
                            for row in self.calls("codesign")))
        build = self.calls("swift")[0]["args"]
        self.assertIn("release", build)
        self.assertEqual(build.count("--arch"), 2)
        self.assertIn("arm64", build)
        self.assertIn("x86_64", build)
        archive = self.root / "dist" / "Perch-1.1.1-app.zip"
        original = archive.read_bytes()
        with zipfile.ZipFile(archive) as zipped:
            self.assertEqual(zipped.namelist(), sorted(zipped.namelist()))
            for info in zipped.infolist():
                self.assertEqual(info.date_time, time.gmtime(EPOCH)[:6])
            executable = zipped.getinfo("Perch.app/Contents/MacOS/Perch")
            self.assertEqual((executable.external_attr >> 16) & 0o777, 0o755)
        stage = self.calls("hdiutil")[0]["stage"]
        applications = next(row for row in stage if row["path"] == "Applications")
        self.assertEqual(applications["target"], "/Applications")
        binary = next(row for row in stage if row["path"] == "Perch.app/Contents/MacOS/Perch")
        self.assertEqual(binary["mtime"], EPOCH)
        report = json.loads((self.root / "dist" / "release-metadata.json").read_text())
        self.assertEqual(report["signature"], "ad-hoc")
        self.assertFalse(report["notarized"])
        self.assertEqual(report["gatekeeper"], "not-accepted")
        sums = (self.root / "dist" / "SHA256SUMS").read_text().splitlines()
        self.assertEqual(len(sums), 2)
        for line in sums:
            digest, name = line.split("  ", 1)
            self.assertEqual(digest, hashlib.sha256((self.root / "dist" / name).read_bytes()).hexdigest())
        second = self.run_bundle()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(archive.read_bytes(), original)

    def test_testing_variant_keeps_instrumentation_and_skips_distribution(self):
        result = self.run_bundle(PERCH_BUILD_VARIANT="testing", ARCHS="arm64")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("not for distribution", result.stdout)
        app = self.root / "dist" / "testing" / "Perch.app"
        self.assertTrue(app.is_dir())
        build = self.calls("swift")[0]["args"]
        self.assertIn(".build-testing", build)
        self.assertIn("-DPERCH_TESTING", build)
        self.assertNotIn("x86_64", build)
        self.assertFalse(list((self.root / "dist").glob("*.dmg")))
        self.assertFalse(list((self.root / "dist").glob("*.zip")))

    def test_developer_id_uses_secure_timestamp_without_claiming_notarization(self):
        keychain = self.root / "synthetic.keychain-db"
        result = self.run_bundle(
            SIGN_ID="Developer ID Application: Synthetic Test", SIGN_KEYCHAIN=keychain,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        sign = self.calls("codesign")[0]["args"]
        self.assertIn("--timestamp", sign)
        self.assertNotIn("--timestamp=none", sign)
        self.assertEqual(sign[sign.index("--keychain") + 1], str(keychain))
        self.assertFalse(self.calls("xcrun"))
        report = json.loads((self.root / "dist" / "release-metadata.json").read_text())
        self.assertEqual(report["signature"], "developer-id")
        self.assertFalse(report["notarized"])
        self.assertEqual(report["gatekeeper"], "not-accepted")

    def test_notarization_requires_real_signing_and_complete_credentials(self):
        missing_identity = self.run_bundle(NOTARIZE=1)
        self.assertNotEqual(missing_identity.returncode, 0)
        self.assertFalse(self.calls("swift"))
        missing_notary = self.run_bundle(SIGN_ID="Developer ID Application: Synthetic Test", NOTARIZE=1)
        self.assertNotEqual(missing_notary.returncode, 0)
        self.assertFalse(self.calls("swift"))

    def test_notarization_staples_app_and_dmg_then_requires_gatekeeper(self):
        key = self.root / "synthetic-notary-key.txt"
        key.write_text("synthetic public test fixture")
        result = self.run_bundle(
            SIGN_ID="Developer ID Application: Synthetic Test", NOTARIZE=1,
            ASC_KEY_ID="synthetic-key-id", ASC_ISSUER_ID="synthetic-issuer-id",
            ASC_KEY_PATH=key, FAKE_GATEKEEPER="accept",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        submissions = [row["args"][2] for row in self.calls("xcrun")
                       if row["args"][:2] == ["notarytool", "submit"]]
        self.assertEqual(len(submissions), 2)
        self.assertTrue(submissions[0].endswith("-app.zip"))
        self.assertTrue(submissions[1].endswith(".dmg"))
        staples = [row for row in self.calls("xcrun") if row["args"][:2] == ["stapler", "staple"]]
        self.assertEqual(len(staples), 2)
        self.assertTrue(any(row["args"][:2] == ["stapler", "validate"] for row in self.calls("xcrun")))
        self.assertFalse(list((self.root / "dist").glob("*-app.zip")),
                         "the unstapled submission ZIP must not be distributed")
        report = json.loads((self.root / "dist" / "release-metadata.json").read_text())
        self.assertTrue(report["notarized"])
        self.assertEqual(report["gatekeeper"], "accepted")
        self.assertEqual(len((self.root / "dist" / "SHA256SUMS").read_text().splitlines()), 1)

    def test_missing_icon_size_still_fails(self):
        result = self.run_bundle(FAKE_MISSING_ICON="icon_16x16.png")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("icon_16x16.png", result.stderr)

    def test_invalid_version_and_variant_fail_before_build(self):
        for changes in ({"VERSION": "1.2/escape"}, {"PERCH_BUILD_VARIANT": "unknown"}):
            with self.subTest(changes=changes):
                result = self.run_bundle(**changes)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.calls("swift"))
                self.log.unlink(missing_ok=True)

    def test_release_workflow_is_manual_capable_but_never_publishes(self):
        self.assertTrue(WORKFLOW.is_file(), "dedicated release workflow is missing")
        text = WORKFLOW.read_text()
        self.assertIn("workflow_dispatch:", text)
        self.assertIn("APPLE_CERTIFICATE", text)
        self.assertIn("ASC_KEY_P8", text)
        self.assertIn("actions/upload-artifact", text)
        self.assertIn("test_packaging.py", text)
        self.assertIn("test_launch_configuration.py", text)
        self.assertIn("check_release.py", text)
        self.assertNotIn("gh release", text)
        self.assertNotIn("softprops/action-gh-release", text)
        self.assertNotIn("self-hosted", text)
        self.assertNotIn("--extract-certificates", text)


if __name__ == "__main__":
    unittest.main()
