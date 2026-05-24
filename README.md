# ClipStack

A macOS menu bar clipboard manager that tracks your copy history and includes items synced from iPhone and iPad via **Universal Clipboard**.

## Features

- **Menu bar app** — lives in the toolbar, no Dock icon
- **Global shortcut** — `⌘⇧X` opens the clip panel (customizable in Settings)
- **Search** — filter history by text, URLs, filenames, and more
- **Universal Clipboard** — items copied on iPhone/iPad appear when synced to your Mac
- **Persistent history** — up to 500 clips stored locally with SwiftData
- **Quick copy** — double-click or press Return to copy a clip back to the pasteboard

## Requirements

- macOS 14+
- Xcode 15+
- For Universal Clipboard: same Apple ID, Wi‑Fi + Bluetooth on, Handoff enabled on all devices

## Build & Run

```bash
cd Projects/ClipStack
xcodegen generate
open ClipStack.xcodeproj
```

Or from the command line:

```bash
xcodegen generate
xcodebuild -scheme ClipStack -configuration Debug build
```

## Usage

1. Launch ClipStack — a clipboard icon appears in the menu bar
2. Copy anything on your Mac (or iPhone when Universal Clipboard syncs)
3. **Click the menu bar icon** for a native macOS menu of recent clips
4. Press **⌘⇧X** for keyboard-only mode: **↑↓** to move, **⌘C** or **Return** to copy, **Esc** to close

## Project Structure

```
ClipStack/
├── ClipStackApp.swift          App entry, menu bar, bootstrap
├── Models/ClipboardEntry.swift SwiftData model
├── Services/
│   ├── PasteboardMonitor.swift Pasteboard polling + Universal Clipboard detection
│   └── ClipboardStore.swift    History persistence
├── Views/
│   ├── ClipStackPanelView.swift Searchable clip list panel
│   └── MenuBarContentView.swift Menu bar dropdown
└── Utilities/
    ├── PanelController.swift   Floating panel window
    └── HotKeyManager.swift     Global keyboard shortcut
```
