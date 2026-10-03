# Clementine — Architecture

Native Swift, **AppKit-first**. SwiftUI only inside on-demand windows (editors,
settings, onboarding). Swift Package Manager (no .xcodeproj), built on GitHub's
macOS runners, assembled into a `.app` by a script, ad-hoc signed, published as
a GitHub Release.

## 1. Repository layout

```
Package.swift                       swift-tools-version 5.10+, Swift 5 language mode
Sources/
  ClementineCore/                   engines + models, no UI
    Formats/    FileKind, Format, UTType mapping, ConversionMatrix (single source of truth)
    Jobs/       Job, JobQueue (actor), OutputNamer, AtomicOutput, ProgressReporter
    Engines/
      Image/    ImageIOEngine, SVGRenderer, ImageCompressor (size targeting)
      Media/    FFmpegLocator, FFmpegRunner (progress parsing), Probe, arg builders per op
      PDF/      PDFRender, PDFText (+OCR fallback), PDFMerge/Split/Organize, PDFCompress
      Document/ AttributedDocIO (NSAttributedString), DOCXWriter, MarkdownImport, TextPaginator
      Subtitle/ SRT/VTT/TXT parse + write
      Archive/  ditto / bsdtar / gzip wrappers, path-safety checks
      Vision/   barcodes, faces, text boxes, foreground mask
    Util/       ZipWriter (stored+deflate, CRC32), ProcessRunner, TempFiles
  Clementine/                       the menu-bar app
    App/        main.swift, AppDelegate, StatusItemController, Settings (UserDefaults), LoginItem, Updater
    Drag/       DragMonitor, WheelPanel, WheelView (CALayer-based), WheelLayout, WheelModel
    HUD/        JobHUDPanel
    Tools/      one folder per dialog/editor (SwiftUI views + small AppKit hosts)
    Onboarding/
    Services/   NSServices provider ("Convert with Clementine…")
    SelfTest/   --self-test, --render-snapshots (used by CI)
Tests/ClementineCoreTests/          unit + end-to-end conversion-matrix tests
scripts/
  build-ffmpeg.sh                   reproducible static ffmpeg/ffprobe build (CI, cached)
  make-icon.swift                   draws the app icon with CoreGraphics → iconset → icns
  make-app.sh                       bundle + Info.plist + helpers + codesign + zip
  install.sh                        one-command install/update on the user's Mac
Resources/                          Info.plist template, licences, menu-bar icon PDFs
.github/workflows/build.yml
.github/swift-problem-matcher.json  turns compiler errors into check-run annotations
```

`ConversionMatrix` is data, not code paths: `(sourceKind, targetFormat) →
engine op`. The wheel, the Services menu, tests and docs all read it. A test
asserts the matrix has ≥ 188 pairs and that each pair is exercised end-to-end.

## 2. Shift-drag detection (no Accessibility permission)

Everything here must be **cheap**: it runs for every mouse drag on the system.

1. `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp])`.
   Global *mouse* monitors need no Accessibility/Input-Monitoring permission.
   Do **not** use a CGEventTap.
2. `leftMouseDown`: remember `NSPasteboard(name: .drag).changeCount` (baseline).
3. `leftMouseDragged`: read `NSEvent.modifierFlags` (cheap, no permission).
   - Wheel hidden and Shift not held → return immediately.
   - Shift held and drag-pasteboard `changeCount != baseline` → a real drag
     session started (not a window move or text selection) → show the wheel.
4. While a drag is active (between mouse-down and mouse-up) run a lightweight
   ~30 Hz timer that re-reads modifier flags, so pressing/releasing Shift or
   Option **without moving the mouse** still shows/hides/switches the wheel.
   Stop the timer on mouse-up. **No timers when idle.**
5. Watchdog: while the wheel is visible also check `NSEvent.pressedMouseButtons`
   — if the button is up, hide (prevents stuck wheels when the up-event is missed).
6. **Pasteboard privacy (macOS 15.4+/26+/27)**: never *read contents* of the
   drag pasteboard from the global monitor — only `changeCount` (and, if proven
   alert-free on macOS 27, `types` or the `detect…` APIs). The file URLs are read
   **inside the wheel's own `NSDraggingDestination` callbacks**
   (`draggingEntered` / `draggingUpdated` / `performDragOperation`), where a drop
   target legitimately owns access. The wheel appears under the pointer, so the
   drag enters it on the next mouse movement; the hub is shown immediately and
   chips animate in as soon as `draggingEntered` delivers the file types. If the
   pasteboard holds no file URLs (text drag etc.), hide at once.
7. File promises (`NSFilePromiseReceiver`, e.g. Photos, Mail): bonus — receive
   into a temp folder, write outputs to `~/Downloads`.

## 3. Wheel panel

- `NSPanel`, `styleMask [.borderless, .nonactivatingPanel]`, transparent,
  `level = .popUpMenu` (verify above full-screen apps),
  `collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]`,
  `canBecomeKey == false` (except the keyboard-navigable variant used by
  Services/hotkey), `hidesOnDeactivate = false`.
- Registered for `.fileURL` (+ file-promise types). One view handles dragging
  for the whole wheel and hit-tests chips by angle/radius; returns `.copy` over a
  chip and `[]` elsewhere; `performDragOperation` returns `false` on hub/empty
  area (snap-back = cancel).
- Rendering: **Core Animation layers** (`CAShapeLayer`/`CATextLayer`, an
  `NSVisualEffectView` disc for the frosted backing). No SwiftUI here. Spring
  scale/opacity entrance with a small stagger; hover scale 1.12 + accent fill.
- Created lazily on first use, then reused (tiny). Positioned centred on the
  pointer and clamped to `screen.visibleFrame`.
- Mode (`convert` / `tools`) and chip list come from `WheelModel` =
  `ConversionMatrix` ∩ settings (enabled/order) ∩ dragged file kinds.

## 4. Jobs

- `JobQueue` actor; lanes with limits: image ≤ min(cores-1, 4), media 1 (1–3
  setting), document 2, archive 2.
- `Job`: inputs, op (+ options), output plan, `Progress` (determinate when
  possible), cancellation. Errors are typed and turned into human sentences.
- While any job runs: `ProcessInfo.beginActivity(.userInitiated)`; end it when
  idle so App Nap can take over.
- Outputs: temp file in the destination folder → atomic rename (see SPEC §1.4).
  Publish an `NSProgress` with `fileURL` for Finder.

## 5. Engines

| Area | Engine |
|------|--------|
| Image decode/encode | **ImageIO** (`CGImageSource`/`CGImageDestination`): JPG, PNG, HEIC, TIFF, BMP, GIF, PDF, AVIF/WebP *decode*. Probe `CGImageDestinationCopyTypeIdentifiers()` at runtime: if AVIF (or WebP) **encode** is supported, use ImageIO; otherwise use ffmpeg (`libaom-av1 -still-picture 1`, `libwebp`). |
| SVG input | Probe `NSImage(contentsOf:)` SVG support on macOS 14+; fallback: offscreen `WKWebView` snapshot (created only for the job, torn down after). |
| Image processing | Core Image (adjust, blur, pixelate), Core Graphics (canvas, collage, annotate, redact), Vision (QR/barcodes, faces, text, foreground mask). Previews always from downsampled `CGImageSourceCreateThumbnailAtIndex`; full-res only on export. |
| Audio/video | **Bundled ffmpeg + ffprobe** (see §6) via `Process`, `-progress pipe:1` for progress, `-nostdin -hide_banner -y`. VideoToolbox H.264/HEVC (`h264_videotoolbox`, `hevc_videotoolbox`, `-q:v` / bitrate), `aac_at` for AAC. AVFoundation (`AVPlayerView`, `AVAssetImageGenerator`, `AVAudioEngine`) for previews only; formats AVFoundation can't play get a temporary low-res H.264 proxy for preview. |
| PDF | **PDFKit** + Core Graphics: render pages (300 DPI default), text, merge/split/organize, info dict. Compression: rewrite with image downsampling/recompression (`QuartzFilter` with a generated `.qfilter`, and/or `PDFDocumentWriteOption.saveImagesAsJPEGOption` / `.optimizeImagesForScreenOption` on macOS 13+); keep text vector. |
| Documents | `NSAttributedString` document readers/writers (plain, RTF, RTFD, DOC, DOCX, ODT, HTML, WordML); `AttributedString(markdown:)` + our styling for MD; TextKit pagination → PDF; own **DOCXWriter** (OOXML: `[Content_Types].xml`, `_rels`, `word/document.xml`, media) built on our **ZipWriter**. |
| Subtitles | own parsers/writers. |
| Archives | `/usr/bin/ditto -c -k --norsrc --keepParent` (ZIP), `/usr/bin/bsdtar` (tar/tgz create; extract zip/tar/gz/rar/7z/bz2/xz), `/usr/bin/gzip`. Validate entry paths before/after extraction. |

## 6. Bundled ffmpeg (built in CI, never on the user's Mac)

`scripts/build-ffmpeg.sh` builds **static, arm64, LGPL** ffmpeg + ffprobe with
deployment target macOS 14.0:

- External libs (all permissive or LGPL): **libmp3lame** (MP3), **libopus**,
  **libogg + libvorbis**, **libvpx** (VP8/VP9 for WebM), **libwebp**,
  **libaom** (AVIF/AV1 encode) or SVT-AV1, **dav1d** (AV1 decode).
- System: `--enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib --enable-iconv`.
- **`--disable-autodetect`** and an isolated `PKG_CONFIG_PATH` so nothing from the
  runner's Homebrew leaks in. Also `--disable-network --disable-indevs
  --disable-outdevs --disable-ffplay --disable-doc --disable-debug`. Do **not**
  use `--enable-gpl` or `--enable-nonfree`.
- CI asserts `otool -L ffmpeg ffprobe` lists only `/usr/lib/*` and
  `/System/Library/*`, and runs a smoke encode for every external encoder.
- No `drawtext` (avoids freetype/fontconfig): text for Visualizer etc. is drawn
  into images with Core Graphics first.
- Cache the result (`actions/cache`, key = hash of the script). Optionally also
  publish it as a release asset (`ffmpeg-<hash>.tar.xz`) so caches can be
  rebuilt quickly. Pin source versions + SHA-256 in the script.
- Ship `THIRD_PARTY_NOTICES` (+ the build script reference) inside the app.
- `FFmpegLocator`: bundled `Contents/Helpers/ffmpeg` → Settings override →
  `CLEMENTINE_FFMPEG` env var (tests).

## 7. Efficiency rules (user has an 8 GB M3 — this is a hard requirement)

- `LSUIElement` agent app; no window at launch; nothing created until needed.
- Idle: zero timers, zero polling, zero animations. Only passive event monitors.
- Global monitor handler: early-return path must be a few µs.
- No SwiftUI/Combine in the always-resident path (status item = `NSMenu`,
  wheel = layers, HUD = small AppKit view).
- Editors: release windows, players, image buffers and Core Image contexts when
  closed (`isReleasedWhenClosed`, nil references, stop `AVPlayer`).
- Work in streams; never load whole videos; image previews downsampled.
- Prefer stream copy and hardware encoders; cap concurrent ffmpeg processes.
- `--self-test` reports `phys_footprint` (task_info) after launch and after a
  simulated job; CI fails if idle footprint > 40 MB.

## 8. Packaging, signing, release

- `swift build -c release --arch arm64`, strip.
- `Clementine.app/Contents/{Info.plist, MacOS/Clementine, Helpers/{ffmpeg,ffprobe}, Resources/{AppIcon.icns, MenuBarIcon.pdf, THIRD_PARTY_NOTICES}}`.
- Info.plist: `CFBundleIdentifier = io.github.kundhan73.clementine`,
  `LSUIElement = YES`, `LSMinimumSystemVersion = 14.0`,
  `CFBundleShortVersionString` from `VERSION`, `NSServices` entry,
  `CFBundleDocumentTypes` (`public.item`, `LSHandlerRank = None`, for "Open
  With"), usage strings: `NSDesktopFolderUsageDescription`,
  `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription`,
  `NSRemovableVolumesUsageDescription`, `NSAppleEventsUsageDescription`.
- Not sandboxed (must write beside originals and run helpers). No Accessibility.
- Ad-hoc codesign inside-out (`codesign --force -s - --timestamp=none` on helpers,
  then the bundle); `codesign --verify --deep --strict` in CI.
- `ditto -c -k --keepParent Clementine.app Clementine.zip`.
- Release: on push to `main`, if tag `v$(cat VERSION)` doesn't exist, CI
  creates that GitHub Release with `Clementine.zip` (marked latest) using
  `GITHUB_TOKEN` (`permissions: contents: write`).
  Stable download URL: `https://github.com/Kundhan73/Clementine/releases/latest/download/Clementine.zip`.

## 9. Install & update on the user's Mac

`scripts/install.sh` (no compiling, just download + copy):
1. `curl -fL` the latest `Clementine.zip` into a temp dir (curl adds no
   quarantine flag, so Gatekeeper won't block the ad-hoc-signed app).
2. Quit a running Clementine, replace `/Applications/Clementine.app`,
   `xattr -dr com.apple.quarantine` defensively, `open` it.

In-app **Check for Updates…**: GitHub Releases API → compare versions →
download → verify bundle id → swap → relaunch. Manual by default.

Expected one-time prompts on the user's Mac: "access files in Desktop /
Documents / Downloads" when first saving there. Updated ad-hoc builds may
re-ask once (new code signature). No Accessibility prompt should ever appear.

## 10. CI (GitHub Actions, `macos-15` arm64 or newer)

Jobs: `ffmpeg` (cached) → `build` (compile, unit tests, conversion-matrix e2e
tests with generated fixtures, `--self-test`, `--render-snapshots`, bundle,
sign, zip, upload) → `release` (main only).

- Compiler errors become **check-run annotations** via
  `.github/swift-problem-matcher.json` (readable with `gh api` without
  downloading logs). On failure, also post the last ~150 lines of the failing
  step as a **commit comment** (fallback channel).
- UI snapshots (wheel in both modes for several kinds, HUD, settings, every
  editor) are rendered offscreen to PNG and attached to a rolling pre-release
  `ci-snapshots` so they can be reviewed visually without a Mac.
