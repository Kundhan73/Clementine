# Clementine user guide

Clementine lives in the menu bar (the small clementine icon). It converts and
edits files on your Mac. Nothing is uploaded anywhere.

## Install or update

Open Terminal and paste:

```bash
curl -fsSL https://raw.githubusercontent.com/Kundhan73/Clementine/main/scripts/install.sh | bash
```

Run the same line again whenever you want the newest version, or use the
menu-bar icon → **Check for Updates…**.

## The wheel

1. Start dragging a file in Finder (or several files).
2. While dragging, hold **⇧ Shift**. A wheel of formats appears under the
   pointer.
3. Drop the file on a format. The converted copy appears next to the
   original, with the same name and the new extension (`photo.heic` →
   `photo.jpg`). The original is never changed, and nothing is overwritten:
   if `photo.jpg` already exists you get `photo 2.jpg`.

Hold **⇧ Shift + ⌥ Option** instead to see **tools** for that kind of file.
You can switch between the two while dragging. Let go of Shift and the drag
carries on as a normal Finder drag. Dropping in the middle of the wheel
cancels.

Other ways in:

- Drop files on the **menu-bar icon**, then click a format or tool.
- Menu-bar icon → **Convert Files…** (⌘O) and pick files.
- In Finder, right-click files → **Services → Convert with Clementine…**.

When the wheel was opened by a click, the arrow keys move between chips,
Return picks one and Esc closes it.

## Where files go

Next to the original by default. Settings → Output can send them to
Downloads or a folder you choose. If a folder can't be written to (a disk
image, for example), the file goes to Downloads and the progress panel says
so. Tools add a word to the name: `clip (trimmed).mp4`, `photo (compressed).jpg`.
Files made from several inputs are named `Merged.pdf`, `Joined.mp4`,
`Collage.png` and so on, next to the first file.

## What it converts

- **Images**: JPG, PNG, HEIC, WebP, AVIF, TIFF, BMP, GIF, SVG, PDF, Word
  (also reads PSD, ICO, ICNS, JPEG 2000, TGA and camera RAW).
- **Audio**: MP3, M4A, WAV, FLAC, OGG, Opus, AIFF, WMA. Tags and cover art are
  kept.
- **Video**: MP4, MOV, MKV, WebM, AVI, WMV, GIF, and the sound out of a video.
  When the streams already fit the new format they're copied, which is
  instant and lossless.
- **PDF and documents**: PDF ↔ Word, text and images (scanned pages are read
  with text recognition); text, RTF, Word, ODT, HTML and Markdown.
- **Subtitles**: SRT ↔ VTT ↔ text.
- **Archives**: make ZIP, TAR, TAR.GZ or GZIP; extract ZIP, TAR, TGZ, GZ, RAR,
  7Z, BZ2, XZ, or repack them.

## Tools (⇧⌥ while dragging)

| Tool | For | What it does |
|---|---|---|
| Compress | photos, video, audio, PDF | Presets, email/Discord/WhatsApp limits, or an exact size |
| Resize | photos, video | Percentage, fit in a box, longest side, 4K/1080p/720p |
| Rotate / Flip | photos, video, PDF | Lossless for JPG, HEIC, MP4 and MOV |
| Crop | photos, video | Drag the box or type exact pixels; aspect presets |
| Adjust | photos | Exposure, contrast, colour, sharpness, grain, vignette… |
| Annotate | photos | Arrows, boxes, pen, highlighter, text, numbered markers |
| Redact | photos, video | Blur, pixelate or black out areas; find faces and text |
| Background | photos | Frame on a colour or gradient; cut out the subject |
| Collage | 2+ photos | Grid, row, column or featured layout |
| Create PDF / Merge PDF | photos, PDFs | One PDF in the order you choose |
| Split | PDF, video, audio | Page ranges; equal parts, every N seconds, or at markers |
| Organize | PDF | Reorder, rotate, duplicate, delete and insert pages |
| Read QR | photos, PDF | Shows the text or link; links open only when you click |
| Metadata | any file | See everything stored in the file; edit title and author |
| Remove Metadata | photos, audio, video, PDF | Strips camera, location and tags |
| Trim | video, audio | Keep a part; fast (no re-encoding) or frame-exact; fades |
| Speed | video, audio | 0.25× to 4×, voices keep their pitch |
| Join | 2+ videos or audio files | One file, in the order you choose |
| Snapshot | video | Saves the exact frame as a full-size PNG |
| Mute / Extract Audio | video | Remove the sound, or keep only the sound |
| Normalize | audio, video | Even loudness (−14 / −16 / −23 LUFS) |
| Channels | audio | Mono, stereo, left, right, swap, with a preview |
| Bleep | audio, video | Replace marked parts with a beep or silence |
| Visualizer | audio | A video with a moving waveform, bars, circle or spectrogram |

## Editors

Every editor saves a new file and leaves the original alone. **Return** (or
⌘S) saves, **Esc** cancels, **⌘Z** undoes where it makes sense.

In the video and audio editors: **Space** plays and pauses, **← →** move one
frame (one tenth of a second for audio), **⇧← ⇧→** move one second. In Trim,
**I** and **O** set the start and end; in Split, **M** adds a marker; in
Snapshot, **C** or Return saves the current frame.

Formats macOS can't play directly (MKV, WebM, OGG and others) get a small
preview copy first; the saved file is always made from the original.

## Settings

- **General**: open at login, the keys (⇧ or ⌃), wheel size, sound, show in
  Finder.
- **Output**: where files go, keep metadata, keep file dates.
- **Quality**: JPG/HEIC/WebP/AVIF quality, PDF page resolution, video codec
  and quality, GIF size.
- **Wheel**: for each kind of file, hide formats or tools you never use and
  drag them into your preferred order.
- **Advanced**: how many videos convert at once, hardware encoding, using
  your own ffmpeg, reset everything.
- **About**: version, update check (optionally once a day), licences.

## Privacy

Clementine never sends your files or anything about them anywhere. The only
network request is the update check, which asks GitHub for the latest release
when you click **Check for Updates…** (or once a day, if you turn that on).

## Troubleshooting

- **"Clementine would like to access files in your Desktop/Documents/Downloads
  folder"**: macOS asks once per folder (and again after an update). Allow it,
  or the converted file can't be saved there.
- **The wheel doesn't appear**: check the menu-bar icon isn't set to **Pause
  Shift-Drag**, and Settings → General has the wheel turned on. Shift has to
  be held while the file is being dragged.
- **Services menu item missing**: it can take a minute to appear the first
  time. Logging out and back in also helps.
- **Something failed**: the progress panel shows the reason; click the ⓘ for
  details.
- **Start over**: Settings → Advanced → Reset All Settings.

## Uninstall

Quit Clementine from its menu, then drag `Clementine.app` from Applications
to the Bin. Its settings live in `~/Library/Preferences/io.github.kundhan73.clementine.plist`.
