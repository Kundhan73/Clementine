# Testing Clementine on your Mac

A short checklist. Everything is built in the cloud; you only download the app.

## Install or update

Open Terminal and run:

```bash
curl -fsSL https://raw.githubusercontent.com/Kundhan73/Clementine/main/scripts/install.sh | bash
```

A small clementine icon appears in the menu bar (top right of the screen).
On first launch a welcome window explains the gesture.

## The shift-drag wheel (0.1)
1. In Finder, start dragging a photo (JPG, PNG or HEIC). While you're dragging,
   hold **⇧ Shift**. A round wheel of formats should appear under the pointer.
2. Move over a format (for example **PNG**). It turns orange and grows.
3. Let go. A small panel at the top right shows progress, then "Saved as …".
   The new file is next to the original. The original is unchanged.
4. Drag again and let go of Shift in the middle of the drag: the wheel should
   disappear and the drag should carry on normally (you can still move the file).
5. Drag with **⇧ Shift + ⌥ Option**: the wheel shows **tools**. Try
   **Remove Metadata** and **Read QR** (on a picture of a QR code).
6. Drop on the middle of the wheel: nothing should happen (the file slides back).
7. Select several photos and shift-drag them together: each one is converted.
   Choose **ZIP** to put them all into one `Archive.zip`.
8. Practice file: the welcome window has a picture you can shift-drag.

## Tools (0.3): hold ⇧ Shift + ⌥ Option while dragging
1. **Compress** a big photo: pick **Email** or type an exact size (for example
   2 MB). The copy is named "… (compressed)" and should be just under the
   size you asked for. Try a video and a PDF too.
2. **Resize** a photo to 50 %, and a video to 720p.
3. **Rotate** a JPG or an iPhone video 90°: the copy should look turned, with
   no visible quality loss.
4. **Create PDF** from a few photos (you can reorder them first), then
   **Merge PDF** two PDFs, then **Split** the result by pages (for example
   `1-2, 3`).
5. Video: **Mute**, **Extract Audio**, **Speed** (2×), **Split** into parts,
   **Join** two clips.
6. Audio: **Normalize** a quiet recording, **Channels** → Mono.

## Editors (0.4): ⇧⌥-drag a photo or PDF, then pick
- **Crop**: drag the corners or the whole box; try the 1:1 and 16:9 buttons;
  ⏎ saves "… (cropped)".
- **Adjust**: move the sliders; hold **Show Original** to compare;
  double-click a slider's name to reset it.
- **Annotate**: arrows, boxes, pen, highlighter, text, numbered markers.
  ⌘Z undoes. Select a drawing to move it; Delete removes it.
- **Redact**: drag over something to hide it; try **Find Faces**, **Find
  Text**, or type a word and press Return. The saved copy has no metadata.
- **Background**: pick a colour or gradient; try **Remove the photo's
  background** on a photo of a person or pet.
- **Collage** (drag 2 or more photos): grid, row, column, featured; drag the
  list to reorder.
- **Metadata**: browse everything stored in the file; edit the title or
  author and **Save Copy**.
- **Organize** (a PDF): drag pages around, rotate, delete, insert other PDFs
  or images, then **Save**.

Each editor saves a new file next to the original; the original is never
changed. Esc or Cancel closes without saving.

## Video and audio editors: ⇧⌥-drag a video or a song
- **Trim**: drag the yellow ends (or press I and O while playing), Space plays.
  Try **Fast** and **Precise** on a video; on a song try **Trim Silence** and
  the fades.
- **Crop** a video: same box as for photos; the sound is kept.
- **Split**: press M to drop markers where you want cuts, or pick equal parts.
- **Snapshot**: step with ← → to the frame you want, press Return; repeat.
- **Redact** a video: drag a box over a face or a number plate; use
  **Starts Here / Ends Here** to limit when it's hidden.
- **Bleep**: drag across the waveform over a word; **Preview** plays it.
- **Visualizer** (songs): pick a style and colour, **Create Video**.
- **Channels**: try **Preview** before applying.
- Settings → **Wheel**: hide a format you never use, drag another to the top,
  then shift-drag a file and check the wheel changed.

## Optional extras (Settings → General / About)
- Turn on **⌃⌥C shows the wheel for the files selected in Finder**, select a
  photo in Finder, press ⌃⌥C. macOS asks once whether Clementine may control
  Finder; allow it.
- Turn on **Notify me when a long conversion finishes** and convert a long
  video: a notification appears when it's done; clicking it shows the file.
- **Check for updates once a day** (About): leave it on or off as you like.

## Other ways in
- Drop files on the menu-bar icon: the wheel appears; click a format.
- Menu-bar icon → **Convert Files…** → pick files → click a format.
- Right-click a file in Finder → **Services → Convert with Clementine…**
  (it can take a minute to appear the first time).

## Things to report
- Did the wheel appear quickly, under the pointer? Did it ever get stuck on
  screen?
- Any "allow access to Desktop/Documents/Downloads" prompts? (Expected once per
  folder, and again after an update.)
- Anything confusing, ugly or slow. Screenshots help (⇧⌘4).
- Memory: open Activity Monitor, find Clementine, and note the "Memory" value
  after it has been idle for a minute (target: under 35 MB).
