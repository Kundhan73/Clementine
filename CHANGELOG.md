# Changelog

## 1.0.0
Polish and performance:
- Even lighter in the background: until you press the mouse button,
  Clementine listens for nothing else. Every build checks that it idles
  under 35 MB and at about 0 % CPU (it measures 9 MB and ~0.1 %).
- More reliable with audio and video: fixed a rare mix-up when reading a
  helper program's output that could make a conversion fail with "Couldn't
  read the media information".
- **Settings → Wheel**, optional daily update check, notifications and the
  ⌃⌥C Finder shortcut (from 0.4) are now covered in the new user guide
  (docs/USER_GUIDE.md).
- VoiceOver labels on editor buttons and drawing areas.

## 0.5.0
Video and audio editors (⇧⌥-drag a video or a song):
- **Trim**: drag the ends or press I / O while playing; **Fast** (instant,
  no quality loss) or **Precise** (frame-exact); fades; **Trim Silence** for
  recordings.
- **Crop** a video (the sound is kept), **Split** at markers you drop with
  M (or into equal parts), **Snapshot** saves the exact frame you stepped to
  as a full-size PNG, **Redact** areas of a video for just the seconds you
  choose.
- **Bleep**: mark words on the waveform, type exact times, preview, then save
  with a beep or silence.
- **Visualizer**: waveform, bars, circle or spectrogram over cover art, a
  gradient or a picture you choose, with a title; much faster than before.
- The video editors show the picture straight away; formats macOS can't play
  (MKV, WebM, OGG…) get a quick preview copy first.

## 0.4.0
Editors (hold ⇧ Shift + ⌥ Option while dragging, then pick a tool):
- **Photos**: **Crop** (aspect presets, exact pixels), **Adjust** (exposure,
  contrast, colour, sharpness, grain, vignette… with before/after),
  **Annotate** (arrows, boxes, pen, highlighter, text, numbered markers),
  **Redact** (blur, pixelate or black out; finds faces and text, or a word you
  type), **Background** (frame on a colour or gradient, or cut out the
  subject), **Collage** (grid, row, column, featured).
- **PDF**: **Organize** pages (reorder, rotate, duplicate, delete, insert).
- **Metadata** for any file: see everything stored in it, edit the title and
  author, or remove it all.
- **Video and audio** (first version): **Trim** (fast or frame-exact, fades,
  trim silence), **Crop** video, **Split** at markers, **Snapshot** (save a
  frame), **Redact** video areas for a time range, **Bleep**, and
  **Visualizer** (turn audio into a video).
- **Channels** has a Preview button.
- **Settings → Wheel**: hide formats and tools you never use and put the rest
  in your own order, per kind of file.
- Optional once-a-day update check (off unless you turn it on).
- Optional: a notification when a long conversion finishes, and ⌃⌥C to show
  the wheel for the files selected in Finder (Settings → General).

## 0.3.0
Tools (hold ⇧ Shift + ⌥ Option while dragging):
- **Compress** images, videos, audio and PDFs: High / Medium / Small,
  Email (25 MB), Discord (10 MB), WhatsApp (16 MB), or an **exact size**
  (it gets as close as it can without going over).
- **Resize** (percentage, fit within, longest edge; 4K/1080p/720p presets),
  **Rotate / Flip** (JPG, HEIC, MP4 and MOV without any quality loss).
- **Remove Metadata** now also for audio, video and PDFs.
- **Read QR** also reads PDFs.
- **Create PDF** from images (and PDFs), **Merge PDF**, **Split** PDFs by
  page ranges and videos/audio into parts, **Join** videos or audio.
- **Speed** (0.25×–4×, natural pitch), **Normalize** loudness (EBU R128),
  **Mute**, **Extract Audio**, **Channels** (mono, stereo, left, right, swap).
- Each tool's settings are remembered.


## 0.2.0
First release you can use.
- **Shift-drag wheel**: hold ⇧ Shift while dragging files in Finder (or any
  app that drags files), drop on a format. ⇧⌥ shows tools.
- **Conversions** (490 source → target pairs, checked automatically on
  every build):
  - Images: JPG, PNG, HEIC, WebP, AVIF, TIFF, BMP, GIF, SVG, PDF, DOCX
    (also reads PSD, ICO, ICNS, JPEG 2000, TGA and camera RAW).
  - Audio: MP3, M4A, WAV, FLAC, OGG, Opus, AIFF, WMA (keeps tags and cover
    art).
  - Video: MP4, MOV, MKV, WebM, AVI, WMV, GIF, and audio out of video.
    Copies streams without re-encoding whenever possible (instant,
    lossless); otherwise uses the Mac's hardware video encoder.
  - Documents: PDF ↔ DOCX/TXT/images (reads scanned pages with OCR), TXT,
    RTF, DOC, DOCX, ODT, HTML, Markdown.
  - Subtitles: SRT ↔ VTT ↔ TXT (also ASS in).
  - Archives: ZIP/TAR/TAR.GZ/GZIP out; ZIP, TAR, TGZ, RAR, 7Z, BZ2, XZ, GZ
    extract or repack.
- Tools: Remove Metadata and Read QR for images.
- Drop files on the menu-bar icon, Convert Files… in the menu, Finder
  Services menu, Recent files, progress panel, Settings, welcome window.
- Originals are never changed; outputs never overwrite anything.
