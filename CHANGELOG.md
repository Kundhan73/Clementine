# Changelog

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
