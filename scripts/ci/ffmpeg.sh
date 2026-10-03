#!/bin/bash
# Provides build/ffmpeg-dist for the current build script: reuse a release-asset
# copy (shared across branches) if there is one, else build and publish it.
# The actions/cache entry in the workflow is the fast path; this runs on a miss.
# Usage: scripts/ci/ffmpeg.sh <cache-key>
set -euo pipefail
key="$1"
dist=build/ffmpeg-dist
tag=ffmpeg-cache
asset="$key.tar.xz"
mkdir -p build
if gh release download "$tag" -p "$asset" -D build --clobber 2>/dev/null; then
  echo "using $asset from release $tag"
  rm -rf "$dist"; mkdir -p "$dist"
  tar -xJf "build/$asset" -C "$dist"
  exit 0
fi
scripts/build-ffmpeg.sh "$dist"
tar -cJf "build/$asset" -C "$dist" .
if ! gh release view "$tag" >/dev/null 2>&1; then
  gh release create "$tag" --prerelease --title "ffmpeg build cache" \
    --notes "Static LGPL ffmpeg/ffprobe built by CI (scripts/build-ffmpeg.sh). Not an app release." || true
fi
gh release upload "$tag" "build/$asset" --clobber || echo "warning: could not upload $asset"
