#!/usr/bin/env bash
# Build Perch.app (and a DMG) from the SwiftPM executable. macOS only.
#   scripts/bundle.sh                 universal release build, ad-hoc signed
#   SIGN_ID="Developer ID Application: You (TEAMID)" scripts/bundle.sh   real signing
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)}"
ARCHS="${ARCHS:-arm64 x86_64}"
OUT=dist
APP="$OUT/Perch.app"

args=(-c release --product Perch)
for a in $ARCHS; do args+=(--arch "$a"); done
swift build "${args[@]}"
BIN=$(swift build "${args[@]}" --show-bin-path)/Perch

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Perch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
# The icon is required: validate it with iconutil so a broken file fails the build.
ICONSET=$(mktemp -d)/AppIcon.iconset
iconutil -c iconset -o "$ICONSET" Resources/AppIcon.icns
for f in icon_16x16.png icon_32x32.png icon_128x128.png icon_256x256.png icon_512x512.png icon_512x512@2x.png; do
  [ -f "$ICONSET/$f" ] || { echo "AppIcon.icns is missing $f" >&2; exit 1; }
done
rm -rf "$(dirname "$ICONSET")"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

ID="${SIGN_ID:--}"
codesign --force --options runtime --timestamp=none --entitlements Resources/Perch.entitlements -s "$ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

rm -f "$OUT/Perch-$VERSION.dmg"
STAGE=$(mktemp -d); cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Perch -srcfolder "$STAGE" -ov -format UDZO "$OUT/Perch-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
echo "Built $APP and $OUT/Perch-$VERSION.dmg"
lipo -info "$APP/Contents/MacOS/Perch"
