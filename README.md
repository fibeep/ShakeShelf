# ShakeShelf

A macOS menu-bar utility that gives your screenshots, text snippets, and colors
a place to land — plus the small developer tools you'd otherwise open a website
for.

Take a screenshot, grab it (the little floating thumbnail macOS shows in the
corner, or the file on your Desktop), **shake the mouse a couple of times while
dragging** — a floating shelf appears. Drop the image on it. The shelf holds as
many images as you like, and you can drag them back out into Slack, Mail,
browsers, Finder… whenever you're ready, long after the original thumbnail
has disappeared.

## Features

- **Keyboard shortcuts** — **⌃⌥⌘S** shows or hides the shelf without touching
  the mouse, **⌃⌥⌘N** opens a note, and **⌃⌥⌘4** captures a screen region
  straight onto the shelf. All work from any app and need no Accessibility
  permission. Pick your own from **Keyboard Shortcuts…** in the menu: click a
  field, press the keys you want. Escape cancels, Delete clears. A shortcut
  must include ⌘, ⌥ or ⌃ so it can't swallow ordinary typing.
- **Capture a region to the shelf** — ⌃⌥⌘4 (or "Capture Region to Shelf")
  gives you the usual macOS crosshair, and the result lands on the shelf
  without ever touching your Desktop. Esc cancels.
- **Notes** — the pencil button in the header, "New Note…" in the menu, or
  ⌃⌥⌘N opens a scratch pad. Type or paste, press ⌘↩, and it lands on the
  shelf as a text snippet. Right-click any text tile → **Edit…** reopens it
  in the same editor.
- **Multi-select** — click to select, ⌘-click to add, ⇧-click for a range,
  click the background to clear. Dragging one selected tile drags them all
  out together, and "Combine Images into PDF" uses the selection when there
  is one.

- **Shake to summon** — shake the cursor left-right while dragging anything and
  the shelf pops up next to the pointer. No permissions needed.
- **Holds multiple items** — items scroll horizontally; each is a real file
  copied into the app's own storage, so they survive relaunches and stay
  available after the original screenshot is gone.
- **Drag in, drag out** — accepts the screenshot floating thumbnail (file
  promises), files from Finder, images dragged from browsers, and raw image
  data. Drag any item out into another app to use it.
- **Text snippets** — drag selected text onto the shelf and it's kept as a
  tile showing a preview. Drag it back out and it arrives as plain text, so
  it pastes straight into a Slack message or email rather than showing up as
  a file attachment. Snippets are stored as `.txt` files, so "Open" edits
  them in TextEdit and the shelf picks up your changes.
- **Add from the clipboard** — the **+** button in the shelf header (or
  "Add Clipboard to Shelf" in the menu-bar menu) stashes whatever you last
  copied, text or image. This is also how clipboard-only screenshots
  (⌃⇧⌘4) get onto the shelf.
- **Auto-add screenshots** *(on by default, toggle in the menu)* — screenshots
  saved to disk are added to the shelf automatically.
- **Menu-bar app** — lives in the menu bar (tray icon), no Dock icon.
  Toggle the shelf, clear it, or quit from there.
- **Eyedropper** — the pipette button in the header (or "Pick Color from
  Screen…" in the menu) opens the system loupe and stores the color as a
  swatch. Drag a swatch into any color well (Xcode, Sketch, the system
  picker) or into a text field to get its hex. Right-click → *Copy as* for
  `rgb()`, `hsl()`, SwiftUI `Color`, `UIColor`, and `NSColor`. Right-click an
  image → **Extract Colors** to lift its palette onto the shelf.
- **Developer tools on any tile** (right-click):
  - *Images* — **Extract Text (OCR)** turns a screenshot into a text snippet
    (on-device, no network); **Redact…** opens an editor where you drag boxes
    over secrets; **Read QR / Barcode**; **Resize to Width…**, **Halve Size
    (2x → 1x)**, convert to PNG/JPEG/HEIC/**PDF**, and **Copy as Base64 Data
    URI**.
  - *Text → Data submenu* — **Format JSON**, **Minify JSON**, **JSON → CSV**
    and **CSV → JSON**. The CSV side follows RFC 4180, so quoted fields
    containing commas, doubled quotes and embedded newlines all survive, and
    tab/semicolon/pipe separated files are detected automatically. Values that
    wouldn't survive a round trip (`007`, `1.10`) stay strings rather than
    being silently renumbered.
  - *Text* — Base64 and URL encode/decode, decode a JWT,
    MD5/SHA-1/SHA-256, upper/lowercase, sort lines, remove duplicate lines,
    trim trailing whitespace, Unix timestamp → date, and **Generate QR Code**
    (the fastest way to get a URL or wifi password onto your phone). Each one
    adds a new tile, so the original snippet is never lost.
- **Combine into One PDF** — merges the selected tiles (or everything, when
  nothing is selected) into a single document, in the order shown. Works on
  images, on PDFs, or on any mix: PDFs contribute all of their pages, and
  each image becomes one page shaped like the screenshot itself rather than
  being letterboxed onto fixed paper. This is both "several screenshots → one
  PDF" and "several PDFs → one PDF".
- **PDF tools** — right-click a PDF tile to **Split into Pages** (one new PDF
  per page) or **Export Pages as PNG**. Documents over 12 pages ask before
  filling the shelf.
- **Stitch Images** — joins the selected screenshots into one tall (or wide)
  image, for pasting a multi-step flow into a chat where a PDF is overkill.
  Images keep their native pixels: a narrower shot is centered rather than
  upscaled, since upscaling visibly softens screenshot text.
- **Diff Selected Snippets** — select exactly two text tiles and get a
  `-`/`+` diff as a new snippet.
- **Save As…** on any tile writes a copy wherever you choose, for when
  dragging isn't convenient.
- Per-item actions (right-click): Open, Copy, Share…, Reveal in Finder, Remove.
  Double-click opens the file. Hover shows a ✕ to remove. Dragging a tile
  onto the Dock's Trash moves its file to the Trash.
- Optional: remove items after dragging them out (the file lingers on disk
  for 90 s so the receiving app can finish uploading it); launch at login.

## Build & run

Requires macOS 13+ and the Xcode command-line tools.

```sh
./build.sh
open dist/ShakeShelf.app
```

The app appears as a tray icon in the menu bar. On first launch the (empty)
shelf is shown once so you know where it lives.

## Notes & limitations

- macOS will ask for permission the first time the app reads your Desktop
  (where screenshots are saved). Approve it so auto-add works. Because the
  app is ad-hoc signed, **rebuilding resets that permission** — expect to
  re-approve after each `./build.sh`. If auto-add ever stops working, check
  System Settings → Privacy & Security → Files and Folders.
- The shake gesture only fires during a real drag that carries files or
  images — shaking while selecting text or scrubbing a slider does nothing.
- Screenshots captured **straight to the clipboard** (⌃⇧⌘4) never touch the
  disk, so they can't be auto-added — use the **+** button to pull them off
  the clipboard, or drag the floating thumbnail onto the shelf.
- Text tiles drag out as text, not as files, so dropping one into a Finder
  window does nothing. Use "Reveal in Finder" to get at the `.txt` file.
- Redaction flattens the hidden regions into a new image — the pixels are
  overwritten, not covered by a removable layer. "Replace original" (off by
  default) deletes the unredacted copy, and only after the new file is
  safely written.
- The eyedropper uses macOS's own `NSColorSampler`, so it needs no Screen
  Recording permission.
- Because text tiles can be dragged in, shaking during *any* text drag can
  summon the shelf — including when you're just repositioning a selection.
  That's the cost of supporting "drag text here" at all.
- Region capture shells out to macOS's own `/usr/sbin/screencapture`, so it
  behaves exactly like ⇧⌘4. Depending on your macOS version you may be asked
  for Screen Recording permission the first time.
- Global shortcuts are registered through Carbon's `RegisterEventHotKey`,
  which needs no permissions — but macOS accepts a registration even when
  another app already owns the combination, so a shortcut that seems dead is
  losing to something else. Pick a different one in Keyboard Shortcuts.
- Text snippets are capped at 1 MB. Past that you get a clear message rather
  than a tile that silently behaves like a file attachment; save the text to
  a file and drop the file instead.
- JSON formatting sorts object keys, because the underlying parser doesn't
  preserve the original order and unsorted output would look shuffled.
- Shelf items are stored in
  `~/Library/Application Support/ShakeShelf/Items` ("Show Items in Finder"
  in the menu opens it). Removing an item from the shelf deletes the copy
  there — never your original file.
