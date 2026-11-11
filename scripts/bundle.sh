#!/usr/bin/env bash
# Build Perch.app (and a DMG) from the SwiftPM executable. macOS only.
#   scripts/bundle.sh                 universal release build, ad-hoc signed
#   SIGN_ID="Developer ID Application: You (TEAMID)" scripts/bundle.sh
# Developer ID uses a secure timestamp. NOTARIZE=1 additionally requires
# ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH; never put credentials in this file.
set -euo pipefail
cd "$(dirname "$0")/.."
PLISTBUDDY="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"
VERSION="${VERSION:-$($PLISTBUDDY -c 'Print CFBundleShortVersionString' Resources/Info.plist)}"
ARCHS="${ARCHS:-arm64 x86_64}"
VARIANT="${PERCH_BUILD_VARIANT:-release}"
NOTARIZE="${NOTARIZE:-0}"
ID="${SIGN_ID:--}"
[[ "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z.-]*$ ]] || { echo "Invalid version: $VERSION" >&2; exit 2; }
case "$NOTARIZE" in 0|1) ;; *) echo "NOTARIZE must be 0 or 1" >&2; exit 2 ;; esac
if [[ "$NOTARIZE" == 1 ]]; then
  [[ -n "$ID" && "$ID" != - ]] || { echo "Notarization requires a Developer ID signing identity" >&2; exit 2; }
  for name in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH; do
    [[ -n "${!name:-}" ]] || { echo "Notarization requires $name" >&2; exit 2; }
  done
  [[ -f "$ASC_KEY_PATH" && -r "$ASC_KEY_PATH" ]] || { echo "ASC_KEY_PATH does not name a readable file" >&2; exit 2; }
fi
if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
  SOURCE_DATE_EPOCH=$(git log -1 --format=%ct 2>/dev/null || printf '946684800')
fi
[[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] || { echo "SOURCE_DATE_EPOCH must be an integer" >&2; exit 2; }
export SOURCE_DATE_EPOCH ZERO_AR_DATE=1
case "$VARIANT" in
  release) OUT=dist; args=(-c release --product Perch) ;;
  testing) OUT=dist/testing; args=(-c release --product Perch --scratch-path .build-testing -Xswiftc -DPERCH_TESTING) ;;
  *) printf 'Unknown build variant: %s\n' "$VARIANT" >&2; exit 2 ;;
esac
APP="$OUT/Perch.app"
DMG_NAME="Perch-$VERSION.dmg"
ZIP_NAME="Perch-$VERSION-app.zip"
DMG="$OUT/$DMG_NAME"
APP_ZIP="$OUT/$ZIP_NAME"

for a in $ARCHS; do args+=(--arch "$a"); done
swift build "${args[@]}"
BIN_DIR=$(swift build "${args[@]}" --show-bin-path)
BIN="$BIN_DIR/Perch"

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 0755 "$BIN" "$APP/Contents/MacOS/Perch"
install -m 0644 Resources/Info.plist "$APP/Contents/Info.plist"
$PLISTBUDDY -c "Set CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
BUNDLE_ID=$($PLISTBUDDY -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")
BUILD_NUMBER=$($PLISTBUDDY -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
[[ "$BUNDLE_ID" == app.perch.mac && -n "$BUILD_NUMBER" ]] || { echo "Invalid bundle metadata" >&2; exit 1; }
# The icon is required: validate it with iconutil so a broken file fails the build.
ICONSET=$(mktemp -d)/AppIcon.iconset
iconutil -c iconset -o "$ICONSET" Resources/AppIcon.icns
for f in icon_16x16.png icon_32x32.png icon_128x128.png icon_256x256.png icon_512x512.png icon_512x512@2x.png; do
  [ -f "$ICONSET/$f" ] || { echo "AppIcon.icns is missing $f" >&2; exit 1; }
done
rm -rf "$(dirname "$ICONSET")"
install -m 0644 Resources/AppIcon.icns "$APP/Contents/Resources/"
install -m 0644 Resources/Localizable.xcstrings "$APP/Contents/Resources/"
for bundle in "$BIN_DIR"/Perch_PerchApp.bundle "$BIN_DIR"/Perch_PerchUI.bundle; do
  [ -d "$bundle" ] || { echo "Missing localization resource bundle: $bundle" >&2; exit 1; }
  cp -R "$bundle" "$APP/Contents/Resources/"
done
# SwiftUI literals resolve against the main bundle; library helpers resolve
# against the resource bundles copied above. SwiftPM compiles xcstrings to these.
for localization in Localizable.strings Localizable.stringsdict; do
  if [ -f "$BIN_DIR/Perch_PerchApp.bundle/$localization" ]; then
    install -m 0644 "$BIN_DIR/Perch_PerchApp.bundle/$localization" "$APP/Contents/Resources/"
  fi
done

sign_args=(--force --options runtime --entitlements Resources/Perch.entitlements)
if [[ "$ID" == - ]]; then
  sign_args+=(--timestamp=none)
  SIGNATURE=ad-hoc
else
  sign_args+=(--timestamp)
  SIGNATURE=developer-id
fi
if [[ -n "${SIGN_KEYCHAIN:-}" ]]; then sign_args+=(--keychain "$SIGN_KEYCHAIN"); fi
codesign "${sign_args[@]}" -s "$ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ "$VARIANT" == testing ]]; then
  echo "Built instrumented test app $APP (not for distribution; $SIGNATURE signed, not notarized)"
  exit 0
fi

# Normalize only packaging metadata. Code signatures remain intact.
normalize_tree() {
  python3 - "$1" <<'PY'
import os
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])
epoch = int(os.environ["SOURCE_DATE_EPOCH"])
paths = sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix())
for path in paths:
    if path.is_symlink():
        continue
    if path.is_dir():
        path.chmod(0o755)
    else:
        executable = bool(path.stat().st_mode & 0o111)
        path.chmod(0o755 if executable else 0o644)
    os.utime(path, (epoch, epoch))
for path in reversed([root] + [path for path in paths if path.is_dir() and not path.is_symlink()]):
    os.utime(path, (epoch, epoch))
PY
}

make_app_zip() {
  rm -f "$APP_ZIP"
  APP="$APP" APP_ZIP="$APP_ZIP" python3 - <<'PY'
import os
from pathlib import Path
import stat
import time
import zipfile

root = Path(os.environ["APP"])
epoch = int(os.environ["SOURCE_DATE_EPOCH"])
# ZIP cannot represent dates before 1980.
timestamp = time.gmtime(max(315532800, epoch))[:6]
paths = sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix())
with zipfile.ZipFile(os.environ["APP_ZIP"], "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for path in paths:
        name = root.name + "/" + path.relative_to(root).as_posix()
        mode = stat.S_IMODE(path.lstat().st_mode)
        if path.is_symlink():
            kind, data = stat.S_IFLNK, os.readlink(path).encode()
            mode = 0o777
        elif path.is_dir():
            kind, data = stat.S_IFDIR, b""
            name += "/"
            mode = 0o755
        else:
            kind, data = stat.S_IFREG, path.read_bytes()
        info = zipfile.ZipInfo(name, timestamp)
        info.create_system = 3
        info.external_attr = (kind | mode) << 16
        if path.is_dir():
            info.external_attr |= 0x10
            info.compress_type = zipfile.ZIP_STORED
        else:
            info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, data)
PY
}

notarize_artifact() {
  local artifact="$1" result status
  result=$(mktemp)
  xcrun notarytool submit "$artifact" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER_ID" --wait --output-format json >"$result"
  status=$(python3 - "$result" <<'PY'
import json
import sys
with open(sys.argv[1]) as stream:
    report = json.load(stream)
print(report.get("status", ""))
PY
)
  rm -f "$result"
  [[ "$status" == Accepted ]] || { echo "Notarization was not accepted" >&2; exit 1; }
}

assess_gatekeeper() {
  local kind="$1" artifact="$2" output
  shift 2
  if output=$(spctl --assess --type "$kind" --verbose=2 "$@" "$artifact" 2>&1); then
    GATEKEEPER=accepted
    printf '%s\n' "$output"
  else
    GATEKEEPER=not-accepted
    printf '%s\n' "$output"
    if [[ "$NOTARIZE" == 1 ]]; then echo "Gatekeeper rejected a notarized artifact" >&2; exit 1; fi
  fi
}

normalize_tree "$APP"
make_app_zip
if [[ "$NOTARIZE" == 1 ]]; then
  notarize_artifact "$APP_ZIP"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  # The submission ZIP has no stapled ticket; never distribute it.
  rm -f "$APP_ZIP"
fi
assess_gatekeeper execute "$APP"
if [[ "$GATEKEEPER" == accepted ]]; then
  echo "Gatekeeper: accepted; notarization=$([[ "$NOTARIZE" == 1 ]] && printf yes || printf no)"
else
  echo "Gatekeeper: not accepted (package is not notarized; expected when notarization was not requested)"
fi

rm -f "$DMG"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Perch.app"
ln -s /Applications "$STAGE/Applications"
normalize_tree "$STAGE"
hdiutil create -volname Perch -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG"
rm -rf "$STAGE"
if [[ "$ID" != - ]]; then
  dmg_sign_args=(--force --timestamp)
  if [[ -n "${SIGN_KEYCHAIN:-}" ]]; then dmg_sign_args+=(--keychain "$SIGN_KEYCHAIN"); fi
  codesign "${dmg_sign_args[@]}" -s "$ID" "$DMG"
  codesign --verify --strict --verbose=2 "$DMG"
fi
if [[ "$NOTARIZE" == 1 ]]; then
  notarize_artifact "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  assess_gatekeeper open "$DMG" --context context:primary-signature
  [[ "$GATEKEEPER" == accepted ]] || exit 1
fi

ARTIFACT_NAMES=("$DMG_NAME")
[[ ! -f "$APP_ZIP" ]] || ARTIFACT_NAMES=("$ZIP_NAME" "${ARTIFACT_NAMES[@]}")
(
  cd "$OUT"
  shasum -a 256 "${ARTIFACT_NAMES[@]}" >SHA256SUMS
)
APP_ZIP="$APP_ZIP" ARTIFACTS="${ARTIFACT_NAMES[*]}" BUNDLE_ID="$BUNDLE_ID" BUILD_NUMBER="$BUILD_NUMBER" \
VERSION="$VERSION" ARCHS="$ARCHS" SIGNATURE="$SIGNATURE" NOTARIZED="$NOTARIZE" GATEKEEPER="$GATEKEEPER" \
python3 - <<'PY'
import json
import os
from pathlib import Path

report = {
    "bundleIdentifier": os.environ["BUNDLE_ID"],
    "version": os.environ["VERSION"],
    "build": os.environ["BUILD_NUMBER"],
    "architectures": os.environ["ARCHS"].split(),
    "signature": os.environ["SIGNATURE"],
    "notarized": os.environ["NOTARIZED"] == "1",
    "gatekeeper": os.environ["GATEKEEPER"],
    "sourceDateEpoch": int(os.environ["SOURCE_DATE_EPOCH"]),
    "artifacts": os.environ["ARTIFACTS"].split(),
    "reproducibility": "Ad-hoc app ZIP uses fixed entry order, modes and SOURCE_DATE_EPOCH timestamps. DMG and signed/notarized containers are hashed per build, not promised byte-identical.",
}
Path("dist/release-metadata.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
PY

if [[ "$NOTARIZE" == 1 ]]; then
  echo "Built $APP and $DMG (Developer ID signed, notarized, stapled and Gatekeeper accepted)"
elif [[ "$ID" == - ]]; then
  echo "Built $APP and $DMG (ad-hoc signed, not notarized)"
else
  echo "Built $APP and $DMG (Developer ID signed, not notarized)"
fi
if [[ -f "$APP_ZIP" && "$ID" == - ]]; then
  echo "Built reproducible ad-hoc app archive $APP_ZIP"
elif [[ -f "$APP_ZIP" ]]; then
  echo "Built app archive $APP_ZIP"
fi
lipo -info "$APP/Contents/MacOS/Perch"
