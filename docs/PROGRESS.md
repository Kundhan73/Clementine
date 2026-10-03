# Progress log

Update this after every meaningful step. It's the source of truth across context
compaction.

## How to work (quick reference)
- Session branch `main-i98ifl`; merge into `main` at each milestone (CI releases
  `v$(VERSION)` from `main`).
- CI: `.github/workflows/build.yml`. Jobs: `ffmpeg` (cached by the hash of
  `scripts/build-ffmpeg.sh`; also stored as an asset on the `ffmpeg-cache`
  pre-release; never cancelled mid-build), `app` (compile, unit tests, lite
  bundle, `--self-test`, `--render-snapshots` → `ci-snapshots` pre-release),
  `build` (needs both: tests with ffmpeg, full bundle, self-test, artifact),
  `release` (main only).
- Reading CI from the VM: `gh` isn't authenticated here, but `curl
  https://api.github.com/repos/Kundhan73/Clementine/...` works (the proxy adds
  auth). Job logs: GitHub MCP `get_job_logs` (curl to the log blob host fails).
  Snapshot PNGs download fine from
  `https://github.com/Kundhan73/Clementine/releases/download/ci-snapshots/<name>.png`.
- Local checks: `docker run --rm -v "$PWD":/src -w /src swift:6.1-noble swift test`
  compiles and tests the platform-neutral core on Linux (ImageIO/AppKit parts
  are `#if canImport` guarded).
- CI runner: macOS 15.7 arm64, Xcode 16.4, Swift 6.1.2.

## 2026-10-03: Planning (local session)
- Researched Tangerine: the website, the App Store listing, the press kit, and
  open-source clones (Kumquat and OrbitDrop, both MIT) for implementation hints.
- Owner decisions: the app is named **Clementine**, the repo
  `Kundhan73/Clementine` is **public** (free macOS CI minutes), and all building
  happens in the cloud and on GitHub Actions. The owner's Mac only downloads
  releases.
- Owner's Mac: Apple M3, 8 GB RAM, macOS 27.0.1, Homebrew and gh installed, no
  Xcode. Ffmpeg is bundled in the app; nothing needs installing on the Mac.
- Wrote `docs/SPEC.md`, `docs/ARCHITECTURE.md` and `CLAUDE.md`.

## 2026-10-03: Milestone 0.0 + 0.1 work (cloud session)
- Pipeline: Package.swift (tools 5.10 → Swift 5 mode, macOS 14), build-ffmpeg.sh
  (ffmpeg 7.1.1 + lame 3.100, opus 1.5.2, ogg 1.3.5, vorbis 1.3.7, vpx 1.15.0,
  webp 1.6.0, aom 3.12.1, dav1d 1.5.1; static, LGPL, `--disable-autodetect`,
  checksums pinned in `scripts/ffmpeg-sources.sha256`), make-icon.swift,
  make-app.sh, install.sh, problem matcher, failure commit comments,
  ci-snapshots pre-release.
  - ffmpeg build fixes so far: needs `--extra-libs=-liconv`; `lavfi` indev
    re-enabled for test signals.
- Core (ClementineCore): Format catalogue, ConversionMatrix (280+ pairs),
  Tool list, WheelContent, WheelLayout, OutputNamer, AtomicOutput,
  OutputPlanner, Job/JobQueue (lanes), ImageCodec/ImageEngine (ImageIO;
  WebP/AVIF via ffmpeg when ImageIO can't encode), image → PDF/SVG/DOCX,
  ZipWriter, DOCXWriter, ArchiveEngine (ZIP/TAR/TGZ create), Remove Metadata,
  Read QR, ProcessRunner, FFmpegLocator/Runner.
- App: DragMonitor, WheelPanel/WheelView/WheelController, HUD, JobCenter,
  StatusItemController (menu, Recent, Pause, drop on icon), Settings (SwiftUI),
  Onboarding with practice file, LoginItem, Updater, Services provider,
  SelfTest (footprint + real conversion), SnapshotRenderer.
- Self-test idle footprint (skeleton app): 8.1 MB.

## Known open questions
- Does NSImage render SVG on macOS 14+? (SVG tests will tell; fallback would
  be an offscreen WKWebView.)
- HEIC encode on CI VMs (no media engine): probed at runtime, tests skip it.

## Next
- Get `build` job green with ffmpeg; first release from `main`.
- Review snapshots (wheel, HUD, settings, onboarding) and iterate.
- Then 0.2: audio/video (smart remux, VideoToolbox), documents, subtitles,
  archives (extract/repack), every pair e2e-tested.
