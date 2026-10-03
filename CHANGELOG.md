# Changelog

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
