# ShakeShelf

**Shake your cursor mid-drag and a shelf appears.** Drop screenshots, text, or
colors on it, then drag them back out whenever you need them — long after the
macOS screenshot thumbnail has vanished. Plus the small developer tools you'd
otherwise open a website for: OCR, JSON/CSV, redaction, an eyedropper, and more.

[![Release](https://img.shields.io/github/v/release/fibeep/ShakeShelf?sort=semver)](https://github.com/fibeep/ShakeShelf/releases/latest)
[![License](https://img.shields.io/github/license/fibeep/ShakeShelf)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-13%2B-blue)
![Arch](https://img.shields.io/badge/universal-Apple%20Silicon%20%2B%20Intel-lightgrey)

<!-- Record a ~10s clip (shake → shelf appears → drop → drag into Slack), save it
     as docs/demo.gif, and uncomment the line below. This is the single highest-
     impact thing you can add to this README. -->
<!-- ![ShakeShelf demo](docs/demo.gif) -->

> **▶ Demo GIF goes here.** A 10-second clip — shake, shelf appears, drop, drag
> back out — communicates this app faster than any paragraph. See
> [Recording the demo](#recording-the-demo).

---

## Install

### Homebrew (recommended)

```sh
brew install --cask fibeep/tap/shakeshelf
```

This needs a one-time tap repo (`fibeep/homebrew-tap`) that holds
[`Casks/shakeshelf.rb`](Casks/shakeshelf.rb) — see
[Publishing the cask](#publishing-the-cask). Until that exists, use the DMG.

### Direct download

Grab `ShakeShelf-x.y.z.dmg` from the
[latest release](https://github.com/fibeep/ShakeShelf/releases/latest), open it,
and drag **ShakeShelf** to Applications.

> This build isn't notarized by Apple, so the first launch is blocked with
> *"Apple cannot check it for malicious software."* Open **System Settings →
> Privacy & Security**, scroll to Security, and click **Open Anyway**. On
> macOS 15+ that's the only route — the old right-click → Open trick is gone.
> Full details in [SHARING.md](SHARING.md).

### Build from source

Requires macOS 13+ and the Xcode command-line tools (`xcode-select --install`).
Locally built apps skip Gatekeeper entirely.

```sh
git clone https://github.com/fibeep/ShakeShelf.git
cd ShakeShelf
./build.sh          # add --fast for a host-only build while iterating
open dist/ShakeShelf.app
```

The app lives in the menu bar (a tray icon, no Dock icon). On first launch the
empty shelf is shown once so you can see where it is.

---

## What it does

| Area | Highlights |
| --- | --- |
| **The shelf** | Shake mid-drag to summon it · holds images, text, and colors · items survive relaunches · drag in from Finder/browsers/the screenshot thumbnail, drag back out into any app |
| **Getting things in** | Auto-add saved screenshots · **+** button pulls from the clipboard · a camera button that captures the full screen, a selection, or a screen recording · a built-in notepad |
| **Global shortcuts** | Show/hide shelf (`⌃⌥⌘S`), new note (`⌃⌥⌘N`), capture region (`⌃⌥⌘4`) — all remappable, no Accessibility permission needed |
| **Multi-select** | Click / ⌘-click / ⇧-click · drag a group out together · batch operations use the selection |
| **Images** | OCR to text · redact secrets · resize · halve 2×→1× · convert PNG/JPEG/HEIC/PDF · base64 data URI · read QR/barcodes |
| **Colors** | Eyedropper (system loupe, no Screen Recording permission) · copy as hex/`rgb()`/`hsl()`/SwiftUI/`UIColor`/`NSColor` · extract a palette from any image |
| **Text** | Format/minify JSON · JSON ⇄ CSV (RFC 4180) · Base64/URL encode-decode · JWT decode · MD5/SHA-1/SHA-256 · case, sort, dedupe · timestamp → date · generate a QR code · diff two snippets |
| **PDF** | Combine images and/or PDFs into one · split a PDF into pages · export pages as PNG |

Every conversion adds a **new** tile, so originals are never lost. Full details
in [Feature reference](#feature-reference) below.

---

## Recording the demo

The gesture is the whole pitch, so show it:

1. `open dist/ShakeShelf.app`, take a screenshot (`⇧⌘4`), and start dragging its
   floating thumbnail.
2. Shake left-right — the shelf appears. Drop the image, then drag it out into
   Slack or Mail.
3. Capture that with any screen recorder (macOS `⇧⌘5`, then convert to GIF, or a
   tool like Kap/Gifski). Keep it under ~10 seconds and a few MB.
4. Save it as `docs/demo.gif` and uncomment the image line near the top of this
   file.

---

## Publishing the cask

`brew install --cask fibeep/tap/shakeshelf` resolves to a repo named
`fibeep/homebrew-tap`. To enable it:

1. Create a public repo `fibeep/homebrew-tap`.
2. Copy [`Casks/shakeshelf.rb`](Casks/shakeshelf.rb) into it at
   `Casks/shakeshelf.rb`.
3. On each release, update `version` and `sha256` in that file (the release
   workflow prints the new sha256 in its run summary).

Until then, people can still install straight from this repo's cask:

```sh
brew install --cask https://raw.githubusercontent.com/fibeep/ShakeShelf/main/Casks/shakeshelf.rb
```

---

## Releasing

`Resources/Info.plist`'s `CFBundleShortVersionString` is the source of the DMG
name, so bump it to match the tag first.

```sh
# after bumping the version in Resources/Info.plist
git tag -a v1.0.1 -m "ShakeShelf 1.0.1"
git push origin v1.0.1
```

The [release workflow](.github/workflows/release.yml) builds a universal DMG,
attaches it to a GitHub release, and prints the sha256 to update the cask with.
To build a DMG locally instead, run `./package.sh` (optionally passing a
`Developer ID Application` identity to sign it — see
[SHARING.md](SHARING.md) for signing and notarization).

---

## Feature reference

- **Shake to summon** — shake the cursor left-right while dragging anything and
  the shelf pops up next to the pointer. No permissions needed.
- **Holds multiple items** — items scroll horizontally; each is a real file
  copied into the app's own storage, so they survive relaunches and stay
  available after the original screenshot is gone.
- **Drag in, drag out** — accepts the screenshot floating thumbnail (file
  promises), files from Finder, images dragged from browsers, and raw image
  data. Drag any item out into another app to use it.
- **Keyboard shortcuts** — `⌃⌥⌘S` shows or hides the shelf, `⌃⌥⌘N` opens a
  note, and `⌃⌥⌘4` captures a screen region straight onto the shelf. All work
  from any app and need no Accessibility permission. Remap them from **Keyboard
  Shortcuts…** in the menu: click a field, press the keys you want. Escape
  cancels, Delete clears. A shortcut must include ⌘, ⌥ or ⌃ so it can't swallow
  ordinary typing.
- **Capture the screen to the shelf** — the camera button in the header (and
  the matching menu-bar items) offers **Capture Full Screen**, **Capture
  Selection…**, and **Record Screen…**. The shelf hides itself first so it's
  never in the shot, then reappears with the new item. `⌃⌥⌘4` is a shortcut
  for the selection capture. Results land on the shelf without ever touching
  your Desktop. Esc cancels a selection; a recording stops from the menu-bar
  stop button. Screen capture needs macOS Screen Recording permission — the
  app points you to the right settings pane the first time it's blocked.
- **Notes** — the pencil button in the header, "New Note…" in the menu, or
  `⌃⌥⌘N` opens a scratch pad. Type or paste, press `⌘↩`, and it lands on the
  shelf as a text snippet. Right-click any text tile → **Edit…** reopens it in
  the same editor.
- **Multi-select** — click to select, ⌘-click to add, ⇧-click for a range,
  click the background to clear. Dragging one selected tile drags them all out
  together, and batch operations use the selection when there is one.
- **Text snippets** — drag selected text onto the shelf and it's kept as a tile
  showing a preview. Drag it back out and it arrives as plain text, so it pastes
  straight into a Slack message or email rather than showing up as a file
  attachment. Snippets are stored as `.txt` files, so "Open" edits them in
  TextEdit and the shelf picks up your changes.
- **Add from the clipboard** — the **+** button in the shelf header (or "Add
  Clipboard to Shelf" in the menu) stashes whatever you last copied, text or
  image. This is also how clipboard-only screenshots (`⌃⇧⌘4`) get onto the
  shelf.
- **Auto-add screenshots** *(on by default, toggle in the menu)* — screenshots
  saved to disk are added to the shelf automatically.
- **Eyedropper** — the pipette button in the header (or "Pick Color from
  Screen…" in the menu) opens the system loupe and stores the color as a
  swatch. Drag a swatch into any color well (Xcode, Sketch, the system picker)
  or into a text field to get its hex. Right-click → *Copy as* for `rgb()`,
  `hsl()`, SwiftUI `Color`, `UIColor`, and `NSColor`. Right-click an image →
  **Extract Colors** to lift its palette onto the shelf.
- **Developer tools on any tile** (right-click):
  - *Images* — **Extract Text (OCR)** turns a screenshot into a text snippet
    (on-device, no network); **Redact…** opens an editor where you drag boxes
    over secrets; **Read QR / Barcode**; **Resize to Width…**, **Halve Size
    (2× → 1×)**, convert to PNG/JPEG/HEIC/**PDF**, and **Copy as Base64 Data
    URI**.
  - *Text → Data submenu* — **Format JSON**, **Minify JSON**, **JSON → CSV**
    and **CSV → JSON**. The CSV side follows RFC 4180, so quoted fields
    containing commas, doubled quotes and embedded newlines all survive, and
    tab/semicolon/pipe separated files are detected automatically. Values that
    wouldn't survive a round trip (`007`, `1.10`) stay strings rather than being
    silently renumbered.
  - *Text* — Base64 and URL encode/decode, decode a JWT, MD5/SHA-1/SHA-256,
    upper/lowercase, sort lines, remove duplicate lines, trim trailing
    whitespace, Unix timestamp → date, and **Generate QR Code** (the fastest
    way to get a URL or wifi password onto your phone). Each one adds a new
    tile, so the original snippet is never lost.
- **Combine into One PDF** — merges the selected tiles (or everything, when
  nothing is selected) into a single document, in the order shown. Works on
  images, on PDFs, or on any mix: PDFs contribute all of their pages, and each
  image becomes one page shaped like the screenshot itself rather than being
  letterboxed onto fixed paper. This is both "several screenshots → one PDF" and
  "several PDFs → one PDF".
- **PDF tools** — right-click a PDF tile to **Split into Pages** (one new PDF
  per page) or **Export Pages as PNG**. Documents over 12 pages ask before
  filling the shelf.
- **Stitch Images** — joins the selected screenshots into one tall (or wide)
  image, for pasting a multi-step flow into a chat where a PDF is overkill.
  Images keep their native pixels: a narrower shot is centered rather than
  upscaled, since upscaling visibly softens screenshot text.
- **Diff Selected Snippets** — select exactly two text tiles and get a `-`/`+`
  diff as a new snippet.
- **Save As…** on any tile writes a copy wherever you choose, for when dragging
  isn't convenient.
- Per-item actions (right-click): Open, Copy, Share…, Reveal in Finder, Remove.
  Double-click opens the file. Hover shows a ✕ to remove. Dragging a tile onto
  the Dock's Trash moves its file to the Trash.
- Optional: remove items after dragging them out (the file lingers on disk for
  90 s so the receiving app can finish uploading it); launch at login.

## Notes & limitations

- macOS will ask for permission the first time the app reads your Desktop
  (where screenshots are saved). Approve it so auto-add works. Because the app
  is ad-hoc signed, **rebuilding resets that permission** — expect to re-approve
  after each `./build.sh`. If auto-add ever stops working, check System Settings
  → Privacy & Security → Files and Folders.
- The shake gesture fires during a real drag that carries files, images, or
  text. Because text tiles can be dragged in, shaking while repositioning a text
  selection can also summon the shelf — that's the cost of supporting "drag text
  here" at all. Shaking while scrubbing a slider or with nothing on the drag
  pasteboard does nothing.
- Screenshots captured **straight to the clipboard** (`⌃⇧⌘4`) never touch the
  disk, so they can't be auto-added — use the **+** button, or drag the floating
  thumbnail onto the shelf.
- Text tiles drag out as text, not as files, so dropping one into a Finder
  window does nothing. Use "Reveal in Finder" to get at the `.txt` file.
- Redaction flattens the hidden regions into a new image — the pixels are
  overwritten, not covered by a removable layer. "Replace original" (off by
  default) deletes the unredacted copy, and only after the new file is safely
  written.
- The eyedropper uses macOS's own `NSColorSampler`, so it needs no Screen
  Recording permission.
- Region capture shells out to macOS's own `/usr/sbin/screencapture`, so it
  behaves exactly like `⇧⌘4`. Depending on your macOS version you may be asked
  for Screen Recording permission the first time.
- Global shortcuts are registered through Carbon's `RegisterEventHotKey`, which
  needs no permissions — but macOS accepts a registration even when another app
  already owns the combination, so a shortcut that seems dead is losing to
  something else. Pick a different one in Keyboard Shortcuts.
- Text snippets are capped at 1 MB. Past that you get a clear message rather
  than a tile that silently behaves like a file attachment; save the text to a
  file and drop the file instead.
- JSON formatting sorts object keys, because the underlying parser doesn't
  preserve the original order and unsorted output would look shuffled.
- Shelf items are stored in `~/Library/Application Support/ShakeShelf/Items`
  ("Show Items in Finder" in the menu opens it). Removing an item from the shelf
  deletes the copy there — never your original file.

## Contributing

Issues and pull requests are welcome. The app is a plain Swift Package (no Xcode
project) — `swift build` compiles it, and each feature is a self-contained file
under `Sources/ShakeShelf/`. Per-tile tools are registered in
`ShelfAction.swift`, so adding one is mostly a matter of appending an action.

## License

[MIT](LICENSE).
