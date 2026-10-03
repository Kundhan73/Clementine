#!/bin/bash
# Builds static, arm64, LGPL ffmpeg + ffprobe for Clementine.
#
# Runs on GitHub's macOS runners (never on the owner's Mac). The result is
# cached by CI, keyed on the hash of this file, so bump anything here only when
# the binaries should actually change. Source checksums live in
# scripts/ffmpeg-sources.sha256 (not part of the cache key).
#
# Usage: scripts/build-ffmpeg.sh <output-dir>
# Output: <output-dir>/bin/{ffmpeg,ffprobe}, <output-dir>/THIRD_PARTY_NOTICES.txt,
#         <output-dir>/BUILDINFO.txt
set -euo pipefail

OUT="${1:?usage: build-ffmpeg.sh <output-dir>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="${CLEMENTINE_FFMPEG_WORK:-$ROOT/build/ffmpeg-work}"
PREFIX="$WORK/prefix"
SRC="$WORK/src"
DL="$WORK/downloads"
SUMS="$ROOT/scripts/ffmpeg-sources.sha256"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# ---- pinned sources ---------------------------------------------------------
FFMPEG_VER=7.1.1
LAME_VER=3.100
OPUS_VER=1.5.2
OGG_VER=1.3.5
VORBIS_VER=1.3.7
VPX_VER=1.15.0
WEBP_VER=1.6.0
AOM_VER=3.12.1
DAV1D_VER=1.5.1

# name|filename|url [url...]
SOURCES=(
  "ffmpeg|ffmpeg-$FFMPEG_VER.tar.xz|https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VER.tar.xz https://www.ffmpeg.org/releases/ffmpeg-$FFMPEG_VER.tar.xz"
  "lame|lame-$LAME_VER.tar.gz|https://downloads.sourceforge.net/project/lame/lame/$LAME_VER/lame-$LAME_VER.tar.gz https://deb.debian.org/debian/pool/main/l/lame/lame_$LAME_VER.orig.tar.gz"
  "opus|opus-$OPUS_VER.tar.gz|https://downloads.xiph.org/releases/opus/opus-$OPUS_VER.tar.gz https://ftp.osuosl.org/pub/xiph/releases/opus/opus-$OPUS_VER.tar.gz"
  "ogg|libogg-$OGG_VER.tar.xz|https://downloads.xiph.org/releases/ogg/libogg-$OGG_VER.tar.xz https://ftp.osuosl.org/pub/xiph/releases/ogg/libogg-$OGG_VER.tar.xz"
  "vorbis|libvorbis-$VORBIS_VER.tar.xz|https://downloads.xiph.org/releases/vorbis/libvorbis-$VORBIS_VER.tar.xz https://ftp.osuosl.org/pub/xiph/releases/vorbis/libvorbis-$VORBIS_VER.tar.xz"
  "vpx|libvpx-$VPX_VER.tar.gz|https://github.com/webmproject/libvpx/archive/refs/tags/v$VPX_VER.tar.gz"
  "webp|libwebp-$WEBP_VER.tar.gz|https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$WEBP_VER.tar.gz"
  "aom|libaom-$AOM_VER.tar.gz|https://storage.googleapis.com/aom-releases/libaom-$AOM_VER.tar.gz"
  "dav1d|dav1d-$DAV1D_VER.tar.xz|https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VER/dav1d-$DAV1D_VER.tar.xz https://get.videolan.org/dav1d/$DAV1D_VER/dav1d-$DAV1D_VER.tar.xz"
)

# ---- isolated environment ---------------------------------------------------
# Nothing from the runner's Homebrew may leak into the binaries: tools are
# symlinked into a private bin dir and PATH is reset to system dirs + that.
PKGCONF="$(command -v pkg-config || command -v pkgconf || true)"
CMAKE="$(command -v cmake || true)"
[ -n "$PKGCONF" ] || { echo "error: pkg-config is required (brew install pkgconf)" >&2; exit 1; }
[ -n "$CMAKE" ] || { echo "error: cmake is required" >&2; exit 1; }
mkdir -p "$WORK/tools"
ln -sf "$PKGCONF" "$WORK/tools/pkg-config"
ln -sf "$CMAKE" "$WORK/tools/cmake"
export MACOSX_DEPLOYMENT_TARGET=14.0
export PATH="$WORK/venv/bin:$WORK/tools:/usr/bin:/bin:/usr/sbin:/sbin"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export CC=clang CXX=clang++
export CFLAGS="-arch arm64 -mmacosx-version-min=14.0 -O2 -I$PREFIX/include"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-arch arm64 -mmacosx-version-min=14.0 -L$PREFIX/lib"
unset CPATH LIBRARY_PATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH

log() { printf '\n==> %s\n' "$*"; }

mkdir -p "$PREFIX" "$SRC" "$DL"

fetch() { # name filename urls...
  local name="$1" file="$2"; shift 2
  local dest="$DL/$file"
  if [ ! -s "$dest" ]; then
    local ok=0
    for url in "$@"; do
      log "download $name: $url"
      if curl -fL --retry 4 --retry-delay 5 --retry-all-errors --connect-timeout 30 -o "$dest.part" "$url"; then
        mv "$dest.part" "$dest"; ok=1; break
      fi
    done
    [ "$ok" = 1 ] || { echo "error: could not download $file" >&2; exit 1; }
  fi
  local got want
  got="$(shasum -a 256 "$dest" | awk '{print $1}')"
  want="$(awk -v f="$file" '$2==f {print $1}' "$SUMS" 2>/dev/null || true)"
  if [ -z "$want" ]; then
    echo "warning: UNPINNED $got  $file (add to scripts/ffmpeg-sources.sha256)"
  elif [ "$got" != "$want" ]; then
    echo "error: checksum mismatch for $file: got $got want $want" >&2; exit 1
  fi
  rm -rf "$SRC/$name"; mkdir -p "$SRC/$name"
  tar -xf "$dest" -C "$SRC/$name" --strip-components 1
}

for entry in "${SOURCES[@]}"; do
  IFS='|' read -r name file urls <<<"$entry"
  # shellcheck disable=SC2086
  fetch "$name" "$file" $urls
done

# meson + ninja for dav1d, isolated from the runner's Python packages.
if [ ! -x "$WORK/venv/bin/meson" ]; then
  log "python venv with meson/ninja"
  /usr/bin/python3 -m venv "$WORK/venv"
  "$WORK/venv/bin/pip" install --quiet meson==1.5.2 ninja==1.11.1.1
fi

autotools_build() { # dir configure-args...
  local dir="$1"; shift
  ( cd "$SRC/$dir"
    ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-dependency-tracking "$@"
    make -j"$JOBS"
    make install )
}

log "lame $LAME_VER"
# The export list names a symbol that doesn't exist (only matters for dylibs,
# removed anyway to keep the build quiet).
sed -i '' '/^lame_init_old$/d' "$SRC/lame/include/libmp3lame.sym"
autotools_build lame --disable-frontend --disable-decoder --disable-gtktest --disable-debug

log "opus $OPUS_VER"
autotools_build opus --disable-doc --disable-extra-programs

log "ogg $OGG_VER"
autotools_build ogg

log "vorbis $VORBIS_VER"
# configure passes a flag clang rejects on arm64.
sed -i '' 's/-force_cpusubtype_ALL//g' "$SRC/vorbis/configure"
autotools_build vorbis --disable-docs --disable-examples --disable-oggtest --with-ogg="$PREFIX"

log "libvpx $VPX_VER"
( cd "$SRC/vpx"
  ./configure --prefix="$PREFIX" --target=arm64-darwin20-gcc \
    --enable-static --disable-shared --enable-pic \
    --disable-examples --disable-tools --disable-docs --disable-unit-tests \
    --disable-vp8-decoder --disable-vp9-decoder --disable-install-bins --disable-install-srcs
  make -j"$JOBS"
  make install )

log "libwebp $WEBP_VER"
autotools_build webp --disable-gl --disable-sdl --disable-png --disable-jpeg \
  --disable-tiff --disable-gif --disable-wic

log "libaom $AOM_VER"
cmake -S "$SRC/aom" -B "$WORK/aom-build" -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DBUILD_SHARED_LIBS=0 -DENABLE_DOCS=0 -DENABLE_EXAMPLES=0 -DENABLE_TESTDATA=0 \
  -DENABLE_TESTS=0 -DENABLE_TOOLS=0 -DCONFIG_AV1_DECODER=0 -DCONFIG_RUNTIME_CPU_DETECT=0
cmake --build "$WORK/aom-build" -j "$JOBS"
cmake --install "$WORK/aom-build"

log "dav1d $DAV1D_VER"
rm -rf "$WORK/dav1d-build"
meson setup "$WORK/dav1d-build" "$SRC/dav1d" --prefix="$PREFIX" --libdir=lib \
  --buildtype=release --default-library=static \
  -Denable_tools=false -Denable_tests=false
ninja -C "$WORK/dav1d-build"
ninja -C "$WORK/dav1d-build" install

# Make sure only static archives are linkable from the prefix.
find "$PREFIX/lib" -name '*.dylib' -delete

log "ffmpeg $FFMPEG_VER"
( cd "$SRC/ffmpeg"
  ./configure --prefix="$PREFIX" \
    --cc=clang --arch=arm64 --target-os=darwin \
    --pkg-config="$WORK/tools/pkg-config" --pkg-config-flags=--static \
    --extra-cflags="-I$PREFIX/include -mmacosx-version-min=14.0" \
    --extra-ldflags="-L$PREFIX/lib -mmacosx-version-min=14.0 -Wl,-dead_strip" \
    --disable-autodetect --enable-static --disable-shared --enable-pthreads \
    --disable-network --disable-indevs --disable-outdevs --disable-ffplay \
    --disable-doc --disable-debug \
    --enable-videotoolbox --enable-audiotoolbox \
    --enable-zlib --enable-bzlib --enable-iconv \
    --enable-libmp3lame --enable-libopus --enable-libvorbis --enable-libvpx \
    --enable-libwebp --enable-libaom --enable-libdav1d \
    --disable-decoder=libaom_av1
  make -j"$JOBS"
  make install )

rm -rf "$OUT/bin"; mkdir -p "$OUT/bin"
cp "$PREFIX/bin/ffmpeg" "$PREFIX/bin/ffprobe" "$OUT/bin/"
strip -x "$OUT/bin/ffmpeg" "$OUT/bin/ffprobe"

log "verify linkage"
for b in "$OUT/bin/ffmpeg" "$OUT/bin/ffprobe"; do
  otool -L "$b"
  bad="$(otool -L "$b" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/)' || true)"
  if [ -n "$bad" ]; then echo "error: $b links non-system libraries:"; echo "$bad"; exit 1; fi
  lipo -archs "$b" | grep -qx arm64 || { echo "error: $b is not arm64-only"; exit 1; }
done
"$OUT/bin/ffmpeg" -hide_banner -version | head -3
if "$OUT/bin/ffmpeg" -hide_banner -buildconf | grep -E -- '--enable-(gpl|nonfree)'; then
  echo "error: GPL/nonfree component enabled"; exit 1
fi

log "smoke test encoders"
T="$WORK/smoke"; rm -rf "$T"; mkdir -p "$T"
FF=("$OUT/bin/ffmpeg" -nostdin -hide_banner -loglevel error -y)
VSRC=(-f lavfi -i "testsrc2=size=160x120:rate=10" -t 1)
ASRC=(-f lavfi -i "sine=frequency=440:sample_rate=48000" -t 1)
"${FF[@]}" "${ASRC[@]}" -c:a libmp3lame -q:a 2 "$T/a.mp3"
"${FF[@]}" "${ASRC[@]}" -c:a libopus -b:a 96k "$T/a.opus"
"${FF[@]}" "${ASRC[@]}" -c:a libvorbis -q:a 5 "$T/a.ogg"
"${FF[@]}" "${ASRC[@]}" -c:a aac_at -b:a 128k "$T/a.m4a"
"${FF[@]}" "${ASRC[@]}" -c:a flac "$T/a.flac"
"${FF[@]}" "${VSRC[@]}" -c:v libvpx-vp9 -row-mt 1 -b:v 200k "$T/v9.webm"
"${FF[@]}" "${VSRC[@]}" -c:v libvpx -b:v 200k "$T/v8.webm"
"${FF[@]}" "${VSRC[@]}" -frames:v 1 -c:v libwebp "$T/i.webp"
"${FF[@]}" "${VSRC[@]}" -frames:v 1 -c:v libaom-av1 -still-picture 1 -cpu-used 6 "$T/i.avif"
"${FF[@]}" "${VSRC[@]}" -c:v libaom-av1 -cpu-used 8 -b:v 100k "$T/v.mkv"
"${FF[@]}" -i "$T/v.mkv" -c:v rawvideo -f null - # dav1d decode
"${FF[@]}" "${VSRC[@]}" -c:v mpeg4 -q:v 4 "$T/v.avi"
"${FF[@]}" "${VSRC[@]}" -c:v wmv2 "$T/v.wmv"
if ! "${FF[@]}" "${VSRC[@]}" -c:v h264_videotoolbox -allow_sw 1 -b:v 500k "$T/v.mp4"; then
  echo "warning: h264_videotoolbox unavailable on this runner (expected on some VMs)"
fi
"$OUT/bin/ffprobe" -v error -show_format -show_streams -of json "$T/v9.webm" >/dev/null
ls -l "$T"

log "notices"
{
  echo "Clementine bundles FFmpeg (https://ffmpeg.org), licensed under the GNU Lesser"
  echo "General Public License version 2.1 or later, built from unmodified sources by"
  echo "scripts/build-ffmpeg.sh in https://github.com/Kundhan73/Clementine with:"
  echo
  for entry in "${SOURCES[@]}"; do
    IFS='|' read -r name file urls <<<"$entry"
    echo "  $file  ${urls%% *}"
  done
  echo
  echo "Configuration:"
  "$OUT/bin/ffmpeg" -hide_banner -buildconf | sed 's/^/  /'
  for pair in "ffmpeg:COPYING.LGPLv2.1" "lame:COPYING" "opus:COPYING" "ogg:COPYING" \
              "vorbis:COPYING" "vpx:LICENSE" "vpx:PATENTS" "webp:COPYING" "webp:PATENTS" \
              "aom:LICENSE" "aom:PATENTS" "dav1d:COPYING"; do
    name="${pair%%:*}"; f="${pair#*:}"
    printf '\n\n==================== %s: %s ====================\n\n' "$name" "$f"
    cat "$SRC/$name/$f"
  done
} > "$OUT/THIRD_PARTY_NOTICES.txt"

{
  echo "ffmpeg $FFMPEG_VER (lame $LAME_VER, opus $OPUS_VER, ogg $OGG_VER, vorbis $VORBIS_VER,"
  echo "vpx $VPX_VER, webp $WEBP_VER, aom $AOM_VER, dav1d $DAV1D_VER)"
  echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(sw_vers -productVersion), $(clang --version | head -1)"
} > "$OUT/BUILDINFO.txt"

ls -lh "$OUT/bin"
log "done"
