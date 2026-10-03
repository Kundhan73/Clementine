# Progress log

Update this after every meaningful step. It's the source of truth across context
compaction.

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

## Next
- Milestone 0.0: the build pipeline (see CLAUDE.md).
