<p align="center"><img src="site/icon.png" width="112" alt="Shelfy icon"></p>

# Shelfy

A native macOS drag-and-drop shelf (SwiftUI + AppKit), inspired by Dropover.

## Install
Website: **https://deep200315.github.io/Shelfy/**

Install or update with one command (no "Open Anyway" prompt; read [the script](site/install.sh) first if you like):

    curl -fsSL https://deep200315.github.io/Shelfy/install.sh | sh

Or download **Shelfy.dmg** from the [latest release](https://github.com/deep200315/Shelfy/releases/latest) and drag Shelfy into Applications.

First launch: free builds aren't notarized by Apple, so macOS blocks Shelfy the first time. Open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. (Or in Terminal: `xattr -dr com.apple.quarantine /Applications/Shelfy.app`.)
Shelfy lives in the **menu bar** (tray icon, top right); it has no Dock icon or window.
Want the newest work in progress? Grab the **Dev build** pre-release (built from `develop`).

## Build & run from source
    ./build.sh && open build/Shelfy.app
Tests: `swift test` · Lint: `swift format lint --strict -r Sources Tests` · See [CONTRIBUTING.md](CONTRIBUTING.md) for branches, CI/CD, and releases.

## Opening a shelf
- **Shake** the pointer left-right while dragging anything
- **⌃⌥D** anywhere (opens at the pointer)
- **Drop onto the menu bar icon** or onto the **MacBook notch**
- Menu bar → New Shelf / New Shelf from Clipboard / Recent Shelves

## On a shelf
- Drop files, folders, images, links, text, file promises (Photos, Mail, browsers)
- Drag the footer to drop **everything at once**; drag a tile for the selection
- Click / ⌘-click / ⇧-click to select · Space = Quick Look · ⌘O = open · ⌫ = remove · ⌘C/⌘V
- Right-click a tile: Open, Quick Look, Show in Finder, Rename (renames the file on disk), actions
- ⋯ menu: Share, AirDrop, Copy, Save Copies To…, ZIP, Convert (PNG/JPEG/HEIC/TIFF),
  Resize, Extract Text (Vision OCR, also PDFs), Run Shortcut, Custom Scripts, name, color, pin, dock
- Empty shelf shows **Instant Actions** (AirDrop, Mail, ZIP, Text): drop straight on them
- Drag a shelf to the left/right screen edge to **dock** it; hover or drag over it to reveal

## Power features
- **Command Bar (⌘K)** on a shelf: type to search every action, arrows + Return to run
- **Hover the pile** to fan out and peek at up to 5 items
- **Detail list**: drag rows to reorder, Return to rename inline, ⌘O to open
- **Suggested actions** based on content: stitch images, images → PDF, merge PDFs, video → GIF, compress video
- **Clipboard history** (⌃⌥V or menu bar): last 60 copies; password-manager content is skipped
- Soft sound + trackpad haptic on drop (toggle in Settings)

## Automation
- Settings → collect new screenshots, or watch any folders
- Custom scripts: executable files in `~/Library/Application Support/Shelfy/Scripts`
  receive selected file paths as arguments. Output paths are added as files, other output as text.

Data lives in `~/Library/Application Support/Shelfy` (shelves.json + Items/ for generated files).
