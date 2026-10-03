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
