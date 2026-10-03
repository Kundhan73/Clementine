# Clementine — Product Spec

Clementine is a personal, independent re-implementation of the *behaviour* of
"Tangerine: File Converter" (tangerineformac.com, Mac App Store id 6813034065,
by Leap Studio). Goal: **feature parity or better**, fully offline, native, and
extremely light when idle.

> Clean-room rule: do not copy Tangerine's name, icon, screenshots, marketing
> text, colours-as-trade-dress or code. Build our own look ("clementine orange").
> Do not copy code from GPL / non-commercial clones (Converty is GPL-3, Daisy is
> PolyForm-Noncommercial). MIT clones (Kumquat, OrbitDrop) may be read for ideas;
> write original code.

## 0. What Tangerine does (research summary)

- Menu-bar utility (no Dock icon). Apple-silicon, macOS 13+, ~13 MB, 100% local.
- **Shift + drag** a file in Finder → a **wheel of output formats** appears
  around the pointer. Drop the file on a format → converted copy is saved
  **next to the original**. Original is never modified.
- **Shift + Option + drag** → the wheel shows **tools** for that exact file
  kind (compress, crop, trim, split, merge, …).
- Claims **188 conversion options** and **25 advanced tools**.
- Batch: several compatible files convert at once, per-job progress, Finder
  integration (reveal / progress).
- Compression with **exact file-size targeting** (images, video, audio, PDF).
- Monetisation (20 free files then $15) — **not replicated**: Clementine has no
  limits, no licensing, no accounts, no analytics.

## 1. Interaction model

### 1.1 Shift-drag format wheel (core feature)
1. User starts dragging one or more files/folders (Finder, Desktop, any app that
   drags file URLs; file promises are a bonus) and holds **⇧ Shift** — before or
   during the drag.
2. A wheel appears **centred on the pointer** within one frame. Hub shows the
   file icon (or a stack + count badge for multiple files) and the mode label
   ("Convert"). Chips around it show the valid targets for *all* dragged files
   (intersection). Ordered by popularity, starting at 12 o'clock, clockwise.
3. Hovering a chip highlights it (grows, fills with accent colour, shows a short
   caption under the hub, e.g. "PNG · lossless"). Drop cursor shows the copy (+)
   badge only over chips.
4. Dropping on a chip starts the job(s). Dropping on the hub or empty wheel area
   = cancel (reject drop → system snap-back animation; nothing is moved).
5. Releasing Shift mid-drag hides the wheel and the drag continues normally
   (so a normal Finder move/copy is still possible). Pressing Shift again shows it.
6. **⇧⌥ Shift+Option** switches the same wheel to **Tools** mode (live, mid-drag,
   either direction).
7. When the drag ends anywhere (mouse up) the wheel fades out. Never leave a
   stuck wheel (watchdog on real mouse-button state).
8. Wheel stays where it appeared (does not follow the pointer). Clamp to the
   visible frame of the screen under the pointer; works across Spaces and over
   full-screen apps; never steals focus from Finder.
9. Up to 12 chips on one ring; more → second ring (or a "More…" chip that opens
   the Convert panel). Folders: archive targets only (ZIP/TAR/TGZ).
10. Respect Reduce Motion; VoiceOver labels on chips; dark/light appearance.

### 1.2 Other entry points (beyond parity, cheap and useful)
- **Drop on the menu-bar icon** → the wheel pops up under the icon (no Shift
  needed). Click a chip to apply.
- **Finder Services menu / Quick Action**: "Convert with Clementine…" → wheel at
  pointer, keyboard navigable (arrows move selection, ⏎ apply, ⎋ cancel).
- **Menu → Convert Files…** → open panel → same wheel/panel.
- Optional global hotkey (Carbon `RegisterEventHotKey`, no permission) that acts
  on the current Finder selection (needs Apple Events permission → off by
  default).

### 1.3 Jobs, progress, results
- Each dropped file = one job (multi-file tools = one job). Image jobs run in
  parallel (≤ cores-1, max 4); media (ffmpeg) jobs 1 at a time by default
  (setting 1–3); documents 2.
- **HUD**: small non-activating panel, top-right of the active screen, one row
  per job: icon, name, target, progress bar, cancel ✕. Success row shows ✓ and
  "Show in Finder", auto-dismisses after ~3 s unless hovered. Errors stay with a
  readable message + "Details".
- **Finder integration**: publish an `NSProgress` (`.file` kind, `fileURL` = the
  output) so Finder draws progress on the output icon; optional "reveal in
  Finder when done" (off by default); optional completion sound (on, subtle).
- Menu bar → "Recent" lists the last 10 outputs (click = reveal).

### 1.4 Output rules
- Same folder as the source, same base name, new extension:
  `photo.heic → photo.jpg`. Collision → Finder style `photo 2.jpg`, `photo 3.jpg`.
  **Never overwrite, never modify the source.**
- Tools add a suffix: `video (trimmed).mp4`, `photo (compressed).jpg`,
  `(cropped)`, `(muted)`, `(1.5x)`, `(normalized)`, `(no metadata)`,
  `(redacted)`, `(framed)`, `(organized)`, …
- Multi-output ops (PDF→images, split): a folder named after the source
  (`report/Page 001.jpg …`, `clip (split)/clip part 1.mp4 …`). One-page PDF →
  single file `report.jpg`.
- Multi-input ops (merge, join, collage, create PDF): written next to the first
  input: `Merged.pdf`, `Joined.mp4`, `Collage.png`, `Images.pdf` (+ collision
  numbering).
- Write to a hidden temp file in the destination folder, atomically rename on
  success; delete temp on failure/cancel. If the folder isn't writable (DMG,
  read-only volume), fall back to `~/Downloads` and say so in the HUD.
- Keep metadata (EXIF/tags/dates inside the file) on conversion by default
  (setting). Strip on Redact.

## 2. Conversions (target ≥ 188 source→target pairs)

The wheel only offers targets that differ from the source format.

### 2.1 Images
Inputs: **JPG/JPEG, PNG, HEIC/HEIF, WebP, TIFF, BMP, GIF, AVIF, SVG**
(bonus inputs via ImageIO: PSD, ICO/ICNS, JPEG-2000, TGA, camera RAW: DNG, CR2,
CR3, NEF, ARW, RAF, ORF, RW2).
Targets: **JPG, PNG, HEIC, WebP, AVIF, TIFF, BMP, GIF, SVG, PDF, DOCX** (+ ZIP).
- Alpha → JPG/BMP: flatten onto white. Keep orientation (apply EXIF orientation).
- Animated GIF/WebP → still formats: first frame. (GIF → video: see 2.3.)
- → PDF: one page sized to the image. → DOCX: image embedded on a page, fit to
  width (our own minimal OOXML writer).
- → SVG: SVG wrapper with the image embedded (exact appearance). Stretch:
  optional "Vectorize" tool (colour quantize + contour trace + curve fit).
- SVG input → raster: render at intrinsic size (min 1024 px on the long edge if
  the SVG has no size) — see ARCHITECTURE for renderer choice.
- Quality defaults: JPG 0.85, HEIC 0.80, WebP 80, AVIF ≈ visually equal to JPG
  0.85; all adjustable in Settings.

### 2.2 Audio
Inputs: **MP3, M4A/AAC, WAV, FLAC, OGG, Opus, AIFF, WMA** (+ anything ffmpeg
decodes: CAF, ALAC, AMR, AC3, …).
Targets: **MP3, M4A (AAC), WAV, FLAC, OGG (Vorbis), Opus, AIFF, WMA** (+ ZIP).
- Preserve tags and cover art where the target supports it.
- Defaults: MP3 VBR ~190 kbps (LAME V2), AAC 256 kbps (AudioToolbox encoder),
  Opus 128 kbps, Vorbis q6, WAV/AIFF 16-bit (keep source sample rate), FLAC
  level 5, WMA 192 kbps.

### 2.3 Video
Inputs: **MP4, MOV, M4V, MKV, WebM, AVI, WMV, GIF** (+ FLV, MPEG, 3GP, TS/MTS).
Targets: **MP4, MOV, MKV, WebM, AVI, WMV, GIF, MP3** (audio extraction;
bonus M4A, WAV) (+ ZIP).
- **Smart remux first**: if source streams fit the target container, stream-copy
  (instant, lossless). Otherwise transcode.
- MP4/MOV/MKV: H.264 via **VideoToolbox (hardware)** + AAC; HEVC option.
  WebM: VP9 (libvpx, `-row-mt 1`, good/fast) + Opus. AVI: MPEG-4 Part 2 + MP3.
  WMV: WMV2 + WMA2. GIF: two-pass palette (palettegen/paletteuse), default
  15 fps, max width 720 (settings).
- Keep rotation, keep audio, keep subtitles where possible (copy into MKV).

### 2.4 Documents
- **PDF → DOCX, JPG, PNG, TXT** (bonus TIFF). Images: every page at **300 DPI**
  (setting 72–600), `Page 001.jpg`… PDF→TXT/DOCX: text layer; if a page has no
  text, OCR it with Vision (en + system languages).
- **TXT → PDF, JPG, PNG, SRT, VTT** (bonus DOCX, RTF, HTML, MD). TXT→SRT/VTT:
  one cue per non-empty line/paragraph, timing estimated from reading speed
  (~15 chars/s, min 1.5 s, max 7 s, 0.1 s gap).
- **DOCX → PDF, TXT** (bonus RTF, HTML, ODT, MD, JPG/PNG pages).
- Bonus inputs via `NSAttributedString` importers: RTF, RTFD, DOC, ODT, HTML,
  Markdown, WordML → PDF, DOCX, TXT, RTF, HTML, ODT.
- No macros/scripts are ever executed. Remote resources in HTML are not loaded.

### 2.5 Subtitles
**SRT ↔ VTT ↔ TXT**: SRT → VTT, TXT; VTT → SRT, TXT (strip cue settings/tags
for TXT). Bonus: ASS/SSA → SRT/VTT via ffmpeg. Handle BOM, CRLF, UTF-16.

### 2.6 Archives
- Any files/folders → **ZIP, TAR, TAR.GZ (TGZ), GZIP** (`.gz` single file only).
  Multiple items → `Archive.zip`.
- **ZIP, TAR, TGZ/GZ, RAR** (+ 7Z, BZ2, XZ) → **Extract** (folder next to the
  archive) or repack to ZIP / TAR / TGZ. RAR/7Z are read-only (extract/repack).
- Zip-slip/absolute-path protection, symlink safety, size/entry-count sanity
  limits, no AppleDouble `__MACOSX` junk in created ZIPs.

## 3. Tools (⇧⌥ wheel) — 25 unique tools

Legend: **[I]** instant (no UI, uses defaults), **[D]** quick dialog (small
panel, remembers last settings, ⏎ to run), **[E]** full editor window with live
preview. All editors: ⏎/⌘S export, ⎋ cancel, ⌘Z/⇧⌘Z undo/redo where it applies.

| # | Tool | Applies to | Kind | Behaviour |
|---|------|-----------|------|-----------|
| 1 | Compress | image, video, audio, PDF | D | Presets (High/Medium/Small, Email 25 MB, Discord 10 MB, WhatsApp 16 MB) **and exact target size** field (KB/MB). Shows original + estimated size. See §3.1. |
| 2 | Resize | image (bonus: video) | D | %, max width/height, longest edge, presets (4K, 1080p, 50%); keep aspect. |
| 3 | Rotate / Flip | image, video, PDF | D | 90° L/R, 180°, flip H/V. Lossless for JPEG orientation when possible. |
| 4 | Crop | image, video | E | Image: movable selection with handles, rule-of-thirds, aspect presets (Free, Original, 1:1, 4:3, 3:2, 16:9, 9:16, 4:5), exact pixel fields. Video: same overlay on a player + timeline scrub, keeps audio. |
| 5 | Adjust | image | E | Live preview: exposure, brightness, contrast, highlights, shadows, saturation, vibrance, warmth, tint, sharpness/detail, clarity, dehaze, grain, noise reduction, vignette. Per-slider reset, before/after. |
| 6 | Annotate | image | E | Pen, highlighter, line, arrow, rectangle, ellipse, text, numbered markers; colours, stroke width, fill; select/move/delete; flattened export. |
| 7 | Redact | image, video | E | Regions: solid / blur / pixelate; move/resize. Image: auto-detect faces and text (Vision) incl. search-to-redact. Video: each region has a time range on a timeline. Output is pixel-destructive; metadata stripped. |
| 8 | Background | image | E | Canvas/frame editor: padding, corner radius, shadow, output ratio, background = none / solid swatches / gradients / image / blurred self; **remove subject background** toggle (Vision, macOS 14+). PNG output. |
| 9 | Collage | 2+ images | E | Layouts grid / row / column / featured; spacing, padding, corner radius, background, output width; drag to reorder. |
| 10 | Create PDF | 1+ images (PDFs mixable) | D | One page per image, page size fit-to-image / A4 / Letter, margins; order = drag order. |
| 11 | Read QR | image, PDF | I | Vision barcode detection (QR, Aztec, PDF417, DataMatrix, EAN, Code128…). Result popover near pointer: text, Copy, Open (http/https only, shows the full URL, opens only on click). |
| 12 | Metadata | all | E | Searchable inspector: image EXIF/GPS/TIFF/IPTC/XMP; media container/tracks/chapters/tags; audio tags + cover; PDF info dict, version, pages, encryption. Edit common fields → save as copy. **Remove all metadata** button. |
| 13 | Remove Metadata | all | I | One-click strip (lossless where possible) → `(no metadata)`. |
| 14 | Trim | video, audio | E | Player + timeline (thumbnails for video, waveform for audio), in/out handles, frame stepping (←/→ frame, ⇧←/→ 1 s, I/O keys), exact time fields; Fast (stream copy, keyframe) vs Precise (re-encode). Audio: trim-silence button, fade in/out. |
| 15 | Speed | video, audio | D | 0.25×–4× presets + custom; pitch preserved; silent video supported. |
| 16 | Split | video, audio, PDF | D/E | Video/audio: markers on timeline, or N equal parts / every X seconds. PDF: every page, every N pages, custom ranges ("1-3, 5, 7-10"). Output folder. |
| 17 | Join | 2+ videos or 2+ audios | D | Reorderable list (initial order = drag order). Mixed formats allowed; first clip sets canvas (scale + letterbox), fps/sample-rate normalised; stream-copy when all identical. |
| 18 | Merge PDF | 2+ PDFs (images allowed) | I | Order = drag/selection order → `Merged.pdf`. |
| 19 | Organize PDF | PDF | E | Page thumbnail grid: reorder (drag), rotate, duplicate, delete, insert pages from dropped PDFs/images, zoom. |
| 20 | Snapshot | video | E | Player with frame stepping; Capture saves the exact frame as full-resolution PNG (`clip 00-01-23.456.png`); multiple captures. |
| 21 | Mute | video | I | Remove audio, stream-copy video → `(muted)`. |
| 22 | Extract Audio | video | I/D | → MP3 by default (M4A/WAV options). |
| 23 | Normalize | audio (video audio track too) | D | EBU R128 two-pass loudnorm. Presets −14 LUFS (streaming), −16 (podcast), −23 (broadcast), custom; true-peak limit (−1 dBTP); shows measured integrated LUFS / true peak / LRA before → after. |
| 24 | Channels | audio | D | Mono, stereo, left-only, right-only, swap; per-side gain (dB); preview playback. |
| 25 | Bleep | audio (video audio track too) | E | Waveform + playback; drag to add intervals; editable list; tone 1 kHz / custom frequency / silence; preview. |
| 26 | Visualizer | audio | D | Make a video from audio: style (waveform, bars/spectrum, circle, spectrogram), colours, background (cover art / image / solid / blurred cover), title text, 1920×1080 / 1080×1080 / 1080×1920, MP4. |

### 3.1 Exact-size compression algorithms
- **Image**: binary-search quality (JPG/HEIC/WebP/AVIF, ≤ 8 encodes); if the
  minimum quality is still too big, downscale by √(target/size) and retry. PNG:
  lossless re-encode → palette quantisation (keeps alpha) → downscale.
- **Video**: total bitrate = target×8/duration×0.96; audio 128k (96k/64k if
  tight); video = rest; below ~300 kbps also lower resolution (720p→480p).
  VideoToolbox H.264 with `-b:v/-maxrate/-bufsize`; if output overshoots, re-run
  once with corrected bitrate. Never exceed the target if at all possible.
- **Audio**: bitrate = target×8/duration, clamped to codec-valid values.
- **PDF**: re-write with image downsampling + JPEG recompression at levels
  (150/110/72 DPI, quality 0.7/0.6/0.5); keep the largest result ≤ target, keep
  text vector/selectable. "Maximum (rasterize pages)" only as an explicit option.

## 4. Menu bar, settings, onboarding

**Menu bar item** (template icon, monochrome clementine): Convert Files…,
Recent ▸, Pause Shift-Drag (toggle), Settings… (⌘,), How to Use, Check for
Updates…, Quit (⌘Q). Accepts file drops (see 1.2).

**Settings** (small, native, tabbed):
- *General*: launch at login (default on, `SMAppService`), enable shift-drag,
  modifier keys (Convert = ⇧, Tools = ⇧⌥; alternatives ⌃ / ⌃⌥), wheel size
  S/M/L, completion sound, reveal in Finder, notifications.
- *Output*: location (beside original / Downloads / custom folder), keep
  metadata, keep file dates.
- *Quality*: per-format defaults listed in §2, PDF DPI, video codec (H.264/HEVC)
  and quality, GIF fps/width.
- *Wheel*: per category, toggle and reorder targets and tools.
- *Advanced*: max concurrent media jobs, hardware encoding on/off, custom
  ffmpeg path override, reset all.
- *About*: version, update check (manual by default; optional daily), licenses.

**Onboarding** (first launch only): one small window — "Hold ⇧ while dragging
a file, then drop it on a format", a practice file the user can shift-drag,
launch-at-login checkbox, Done.

## 5. Non-functional requirements
- **Idle cost**: 0.0 % CPU, no timers/polling while idle, physical footprint
  ≤ 35 MB (target 20–30 MB). The user's Mac is an M3 with **8 GB RAM**.
- **Responsiveness**: wheel visible ≤ 1 frame after Shift is detected; chip
  hover feedback 60–120 fps; editors open < 300 ms.
- **Speed**: hardware encoders, stream-copy whenever possible, parallel images.
- **Privacy**: no network at all except the user-triggered update check against
  GitHub Releases. No analytics, no crash upload.
- **Safety**: sources read-only; atomic outputs; sane limits (e.g. 30k px/side,
  ≤ 2 GB unpacked archives) with clear messages, never crashes on bad input.
- **Platform**: Apple silicon (arm64), deployment target macOS 14.0, tested on
  the user's macOS 27.

## 6. Beyond parity (after v1.0, only if time allows)
Reviews of Tangerine ask for these: **EPUB** output (from DOCX/TXT/MD/HTML/PDF
text), **Pages/Keynote/Numbers → PDF** (if the iWork app is installed, via
Apple Events export; else embedded preview), raster → SVG vectorization,
searchable-PDF OCR, PDF watermark, subtitle time-shift, CLI (`clementine
convert in.mov --to mp4`).
