#!/bin/bash
# Installs or updates Clementine from the latest GitHub Release.
# Nothing is compiled: it downloads Clementine.zip, checks it, and copies the
# app into /Applications (or ~/Applications if /Applications isn't writable).
#
#   curl -fsSL https://raw.githubusercontent.com/Kundhan73/Clementine/main/scripts/install.sh | bash
set -euo pipefail

URL="${CLEMENTINE_URL:-https://github.com/Kundhan73/Clementine/releases/latest/download/Clementine.zip}"
BUNDLE_ID="io.github.kundhan73.clementine"

say() { printf '\033[1;38;5;208m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "Clementine runs on macOS only."
[ "$(uname -m)" = arm64 ] || die "Clementine needs a Mac with Apple silicon."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

say "Downloading the latest Clementine…"
curl -fL --progress-bar --retry 3 -o "$tmp/Clementine.zip" "$URL" || die "download failed ($URL)"
ditto -x -k "$tmp/Clementine.zip" "$tmp/unpacked" || die "the download is not a valid zip"
app="$tmp/unpacked/Clementine.app"
[ -d "$app" ] || die "the download doesn't contain Clementine.app"
id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
[ "$id" = "$BUNDLE_ID" ] || die "unexpected bundle identifier '$id'"
/usr/bin/codesign --verify --deep --strict "$app" 2>/dev/null || die "the app's signature doesn't verify"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"

dest=/Applications
if [ ! -w "$dest" ]; then
  dest="$HOME/Applications"
  mkdir -p "$dest"
fi

if pgrep -x Clementine >/dev/null 2>&1; then
  say "Quitting the running Clementine…"
  pkill -x Clementine || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Clementine >/dev/null 2>&1 || break; sleep 0.3; done
  pkill -9 -x Clementine 2>/dev/null || true
fi

say "Installing Clementine $version into $dest…"
rm -rf "$dest/Clementine.app"
ditto "$app" "$dest/Clementine.app"
xattr -dr com.apple.quarantine "$dest/Clementine.app" 2>/dev/null || true

say "Opening Clementine. Look for the clementine icon in the menu bar."
open "$dest/Clementine.app"
echo
echo "Tip: hold Shift while you drag a file in Finder to see the format wheel."
