# Clementine

A fast, fully offline file converter for macOS that lives in the menu bar.

- **Hold ⇧ Shift while dragging a file.** A wheel of formats appears under the
  pointer. Drop the file on one, and the converted copy is saved next to the
  original.
- **Hold ⇧ Shift + ⌥ Option** to get tools for that kind of file instead:
  compress to an exact size, crop, adjust, annotate, redact, trim, split, join,
  merge PDFs, normalize audio, and more.
- Images, audio, video, PDFs and documents, subtitles, and archives. Everything
  stays on your Mac.
- It's built to stay out of the way: no Dock icon, no CPU use while idle, and a
  small memory footprint.

Clementine is an independent, personal project. It is not affiliated with
Tangerine or Leap Studio.

## Install or update

Run this in Terminal. It downloads the latest build from this repo's Releases;
nothing is compiled on your Mac.

```bash
curl -fsSL https://raw.githubusercontent.com/Kundhan73/Clementine/main/scripts/install.sh | bash
```

## Status

| Milestone | State |
|---|---|
| Spec and architecture | ✅ done |
| 0.0 Build pipeline (GitHub Actions → Releases) | ⏳ |
| 0.1 Shift-drag wheel + image conversions | ⏳ |
| 0.2 All conversions (audio, video, documents, subtitles, archives) | ⏳ |
| 0.3 Instant and dialog tools | ⏳ |
| 0.4 Image and PDF editors | ⏳ |
| 0.5 Media editors | ⏳ |
| 1.0 Polish and performance | ⏳ |

See [docs/SPEC.md](docs/SPEC.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
