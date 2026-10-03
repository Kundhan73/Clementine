# Progress log

Update this after every meaningful step. It's the source of truth across context
compaction.

## How to work (quick reference)
- Session branch `main-i98ifl`; fast-forward `main` to a green commit at each
  milestone (CI releases `v$(VERSION)` from `main`).
- CI: `.github/workflows/build.yml`. Jobs: `ffmpeg` (cached by the hash of
  `scripts/build-ffmpeg.sh`; also stored as an asset on the `ffmpeg-cache`
  pre-release; never cancelled mid-build), `app` (compile, unit tests, lite
  bundle, `--self-test`, `--render-snapshots` → `ci-snapshots` pre-release),
  `build` (needs both: tests with ffmpeg, full bundle, self-test, artifact),
  `release` (main only, notes from `CHANGELOG.md`).
- Reading CI from the VM: `gh` isn't authenticated here, but `curl
  https://api.github.com/repos/Kundhan73/Clementine/...` works (the proxy adds
  auth). A helper lives in the session scratchpad (`ci.sh runs|jobs|ann|comments`).
  Job logs: GitHub MCP `get_job_logs` (curl to the log blob host fails).
  Tests print `::notice title=…::` lines so results show up as annotations.
  Snapshot PNGs download from
  `https://github.com/Kundhan73/Clementine/releases/download/ci-snapshots/<name>.png`.
- Local checks: `docker run --rm -v "$PWD":/src -w /src swift:6.1-noble swift test`
  compiles and tests the platform-neutral core on Linux (ImageIO/AppKit parts
  are `#if canImport` guarded). The app target only exists on macOS.
- CI runner: macOS 15.7 arm64, Xcode 16.4, Swift 6.1.2.

## Status

| Milestone | State | Notes |
|---|---|---|
| 0.0 Pipeline | ✅ | static LGPL ffmpeg cached; bundle verified (`codesign --verify --deep --strict`, `otool -L` system-only) |
| 0.1 Core gesture | ✅ | wheel, HUD, image matrix, settings, onboarding, login item |
| 0.2 All conversions | ✅ v0.2.0 | 490 pairs; 465 e2e-tested on CI (RAW/AMR/RAR have no fixture generator) |
| 0.3 Instant + dialog tools | ✅ tests green | released together with the first editors |
| 0.4 Image + PDF editors | 🔨 | code written; compile/snapshot review in progress |
| 0.5 Media editors | ⏳ | |
| 1.0 Polish | ⏳ | |

## Log

### 2026-10-03: Planning (local session)
- Researched the reference app's public material and the MIT clones (Kumquat,
  OrbitDrop) for implementation hints only.
- Owner decisions: the app is named **Clementine**, the repo
  `Kundhan73/Clementine` is **public** (free macOS CI minutes), and all building
  happens in the cloud. The owner's Mac (M3, 8 GB, macOS 27.0.1, no Xcode) only
  downloads releases.
- Wrote `docs/SPEC.md`, `docs/ARCHITECTURE.md` and `CLAUDE.md`.

### 0.0 + 0.1
- Pipeline: Package.swift (tools 5.10 → Swift 5 mode, macOS 14), build-ffmpeg.sh
  (ffmpeg 7.1.1 + lame 3.100, opus 1.5.2, ogg 1.3.5, vorbis 1.3.7, vpx 1.15.0,
  webp 1.6.0, aom 3.12.1, dav1d 1.5.1; static, LGPL, `--disable-autodetect`,
  checksums pinned in `scripts/ffmpeg-sources.sha256`), make-icon.swift,
  make-app.sh, install.sh, problem matcher, failure commit comments,
  ci-snapshots pre-release.
- ffmpeg build lessons: needs `--extra-libs=-liconv`; `--enable-indev=lavfi` for
  test signals; libaom needs `CONFIG_RUNTIME_CPU_DETECT=1` and SVE/SVE2 off
  (otherwise "Illegal instruction" on the runners).
- App: DragMonitor (global monitor + drag-pasteboard changeCount, pasteboard
  contents read only in the wheel's dragging-destination callbacks), wheel
  panel, HUD, JobCenter, status item, Settings, Onboarding, LoginItem, Updater,
  Services provider, SelfTest, SnapshotRenderer.

### 0.2 (released v0.2.0)
- Media via ffmpeg (stream copy first, then VideoToolbox, then software),
  documents (NSAttributedString + TextKit pagination, Markdown, DOCX writer),
  PDF (PDFKit, Vision OCR), subtitles, archives (ditto/bsdtar/gzip/bzip2/xz).
- ffprobe JSON can contain invalid UTF-8 (tags): repaired before parsing.

### 0.3 tools (green on CI)
- Compress (presets + exact size by bisection), Resize, Rotate/Flip (JPEG
  lossless at the byte level: `JPEGOrientation`; video via display matrix),
  Remove Metadata (JPEG byte-level strip), Read QR (images + PDFs), Create PDF,
  Merge PDF, Split (PDF ranges, media segments), Join, Speed, Normalize
  (EBU R128 two-pass), Mute, Extract Audio, Channels.
- Dialogs in a floating panel near the pointer; settings remembered.

### 0.4 editors (in progress)
- Neutral models in `Editing/EditorModels.swift`; rendering in
  `Engines/Image/ImageEditing.swift` (crop, annotations, redaction with
  Vision face/text search, frame/background with subject cut-out, collage)
  and `ImageAdjust.swift` (Core Image).
- Editors (`Sources/Clementine/Tools/Editors/`): previews are downsampled
  (≤ 1800 px); exports re-render at full resolution through the job queue
  (`ToolOptions.crop/adjust/annotate/redact/background/collage/organizePDF/metadata`),
  so they get the HUD, naming and Recent. Windows release their images on
  close.
- Snapshots render every editor with generated sample photos and a PDF.

## Known open questions
- HEIC encode on CI VMs (no media engine): probed at runtime; tests skip it.
- RAW/AMR/RAR sources can't be generated on CI; covered by decoder support
  only.

## Next
- Get the editors commit green; review `editor-*` snapshots; release.
- 0.5 media editors (Trim with waveform, Video Crop, Split markers, Snapshot,
  Video Redact, Channels preview, Bleep, Visualizer).
- 1.0 polish: wheel customization, keyboard navigation, update check, perf
  audit, accessibility, user guide.
