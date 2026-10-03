# Clementine — working instructions for Claude

You are building **Clementine**, a native macOS menu-bar file converter with
feature parity with "Tangerine: File Converter" (shift-drag format wheel,
⇧⌥ tools wheel, 188+ conversions, 25 tools), for the repo owner's personal use.

Read these before writing code:
- `docs/SPEC.md`: what to build (features, behaviours, naming, non-functional
  requirements).
- `docs/ARCHITECTURE.md`: how to build it (modules, drag detection, engines,
  ffmpeg, packaging, CI, install).
- `docs/PROGRESS.md`: where things stand. Create it if it's missing and keep it
  current. It is your memory across context compaction.

## Hard constraints
1. **Nothing builds on the user's Mac.** It's an M3 with 8 GB RAM, and the
   owner asked for all building to happen in the cloud. You run on a Linux
   x86_64 VM, which cannot compile AppKit/SwiftUI/AVFoundation code. **GitHub
   Actions macOS runners are the compiler.** The user's Mac only downloads the
   finished `Clementine.zip` (see `scripts/install.sh`).
2. **Efficiency is a feature.** The app runs all the time on an 8 GB machine:
   idle 0 % CPU, ≤ 35 MB footprint, no idle timers. Follow ARCHITECTURE §7.
3. **Clean room.** Don't use Tangerine's name, icon, text or code. Don't copy
   GPL or non-commercial clone code (Converty, Daisy). Write original code.
4. **Offline and safe.** No telemetry. The only network call is the
   user-initiated update check against this repo's Releases. Never modify a
   source file. Write outputs atomically.
5. **No paywall or limits** of any kind.

## The build/feedback loop (CI is your compiler)
1. Make a coherent batch of changes. Don't push every tiny edit: each push
   costs a CI run, and the owner's Claude usage limits are shared with this
   session.
2. `git push`. Then find the run and wait for it in the background:
   `gh run list --branch "$(git branch --show-current)" --limit 1 --json databaseId,status`
   `gh run watch <id> --interval 30 --exit-status` (run in the background, then
   continue).
3. On failure, read the errors in this order:
   - `gh run view <id> --log-failed`. This may fail, because log downloads come
     from a blob host that the VM's network allowlist may block.
   - Annotations: `gh api repos/Kundhan73/Clementine/check-runs/<job-id>/annotations`.
     Get job ids from `gh run view <id> --json jobs`.
   - The commit comment that CI posts on failure:
     `gh api repos/Kundhan73/Clementine/commits/<sha>/comments`.
4. UI review: CI renders snapshots of the wheel, HUD and editors into the
   `ci-snapshots` pre-release. Fetch them with
   `gh release download ci-snapshots -p '*.png' -D /tmp/snaps --clobber`, then
   look at them with the Read tool. Iterate until they look good in light and
   dark mode.
5. Optional: install a Linux Swift toolchain to unit-test platform-neutral code
   (subtitles, naming, matrix, ZipWriter) locally. Keep those files free of
   Apple-only imports, or guard them with `#if canImport(AppKit)`.

Guidance: Swift 5 language mode (avoid a Swift 6 strict-concurrency error
avalanche) with explicit `@MainActor` for UI. Deployment target macOS 14.0; gate
newer APIs with `if #available`. Arm64 only. Keep the build warning-free where
practical.

## Milestones (ship a usable release after each one)
Bump `VERSION`. CI releases `v$(VERSION)` from `main` automatically. Update
`docs/PROGRESS.md` and the README status table.

| Version | Milestone | Done when |
|---|---|---|
| 0.0.x | **Pipeline**: Package.swift skeleton, cached static ffmpeg build, make-app (icon, Info.plist, helpers, ad-hoc sign, zip), release, install.sh, problem matcher, failure comment, snapshot pre-release | CI green; release zip verified (`codesign --verify --deep --strict`, `otool -L` shows only system libs) |
| 0.1 | **Core gesture**: status item + menu, DragMonitor, wheel (convert + tools modes), JobQueue, HUD, all image conversions, output naming, basic settings, launch at login, onboarding | Image matrix e2e tests pass; snapshots look right. **Tell the owner to install and try shift-drag on their Mac.** |
| 0.2 | **All conversions**: audio, video (smart remux + VideoToolbox), documents, subtitles, archives | Full matrix ≥ 188 pairs, every pair e2e-tested in CI |
| 0.3 | **Instant and dialog tools**: Compress ×4 with exact size, Resize, Rotate, Remove Metadata, Mute, Extract Audio, Read QR, Create PDF, Merge PDF, Split PDF, Join, Speed, Normalize | Engine tests per tool, including size targeting within limits |
| 0.4 | **Image and PDF editors**: Crop, Adjust, Annotate, Redact, Background (+ remove bg), Collage, Metadata inspector, Organize PDF | Snapshot review; export tests |
| 0.5 | **Media editors**: Trim (video + audio waveform), Video Crop, Split markers, Snapshot, Video Redact, Channels, Bleep, Visualizer | Snapshot review; export tests |
| 1.0 | **Polish and performance**: wheel customization, Services menu, status-item drop, keyboard nav, updater, perf audit (`--self-test` footprint gate), accessibility, user guide | All of SPEC done; idle ≤ 35 MB |

Keep going from one milestone to the next without waiting for the owner. Stop
only when you're blocked on something only the owner can do.

## Talking to the owner
- They aren't necessarily a developer. Write short, plain updates: what's new,
  what to try, and the one-line install/update command:
  `curl -fsSL https://raw.githubusercontent.com/Kundhan73/Clementine/main/scripts/install.sh | bash`
- Real-gesture testing on macOS 27 happens on their Mac. Keep
  `docs/TESTING.md` as a short manual checklist they can follow, and ask them
  to report what they see.
- Never ask them to install Xcode or build anything locally.

## Git
- Solo project: commit to `main` directly (or merge the session branch into
  `main` at each milestone). Keep `main` green.
- Use clear commit messages. Don't commit generated binaries (ffmpeg, .app,
  .zip). Those go to the CI cache and to Releases.
