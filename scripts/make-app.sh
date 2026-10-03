#!/bin/bash
# Assembles Clementine.app from the SwiftPM release build, draws the icon,
# writes Info.plist, adds the ffmpeg helpers, ad-hoc signs and zips it.
#
# Usage: scripts/make-app.sh
# Env:   FFMPEG_DIST    dir containing bin/ffmpeg, bin/ffprobe (default build/ffmpeg-dist)
#        REQUIRE_FFMPEG 1 = fail if the helpers are missing (CI)
#        BUILD_NUMBER   CFBundleVersion (default 1)
#        OUT            output dir (default build/app)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FFMPEG_DIST="${FFMPEG_DIST:-$ROOT/build/ffmpeg-dist}"
OUT="${OUT:-$ROOT/build/app}"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="${BUILD_NUMBER:-1}"
BUNDLE_ID="io.github.kundhan73.clementine"
APP="$OUT/Clementine.app"

echo "==> swift build (release)"
swift build -c release --product Clementine
BIN="$(swift build -c release --show-bin-path)/Clementine"

echo "==> bundle $APP ($VERSION build $BUILD)"
rm -rf "$APP" "$OUT/Clementine.zip"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/Clementine"
strip -S -x "$APP/Contents/MacOS/Clementine"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> icon"
rm -rf "$OUT/AppIcon.iconset"
swift scripts/make-icon.swift "$OUT/AppIcon.iconset"
iconutil -c icns "$OUT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> helpers"
if [ -x "$FFMPEG_DIST/bin/ffmpeg" ] && [ -x "$FFMPEG_DIST/bin/ffprobe" ]; then
  cp "$FFMPEG_DIST/bin/ffmpeg" "$FFMPEG_DIST/bin/ffprobe" "$APP/Contents/Helpers/"
  cp "$FFMPEG_DIST/THIRD_PARTY_NOTICES.txt" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
elif [ "${REQUIRE_FFMPEG:-0}" = 1 ]; then
  echo "error: ffmpeg helpers not found in $FFMPEG_DIST" >&2
  exit 1
else
  echo "warning: no ffmpeg helpers; audio/video features will be unavailable"
  rmdir "$APP/Contents/Helpers"
fi

echo "==> codesign (ad-hoc, inside-out)"
if [ -d "$APP/Contents/Helpers" ]; then
  for h in ffmpeg ffprobe; do
    codesign --force --sign - --timestamp=none --identifier "$BUNDLE_ID.$h" "$APP/Contents/Helpers/$h"
  done
fi
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> zip"
( cd "$OUT" && ditto -c -k --keepParent Clementine.app Clementine.zip )
ls -lh "$OUT/Clementine.zip"
du -sh "$APP"
