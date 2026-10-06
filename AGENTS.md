# ClipStack Development Guide

## Overview

ClipStack is a native macOS menu bar clipboard manager built with Swift 5.9, AppKit/SwiftUI, and SwiftData. It tracks copy history, supports Universal Clipboard from iPhone/iPad, includes screen capture/recording features, and offers window resizing presets.

## Cursor Cloud specific instructions

### Environment Constraints

This is a **macOS-only** application. The full build (`xcodebuild`) and run cycle requires macOS 14+ with Xcode 15+, an Apple Development certificate, and `xcodegen`. On Linux cloud VMs, only the following development tasks are possible:

- **Linting**: `swiftlint lint` (requires `LINUX_SOURCEKIT_LIB_PATH` set — see below)
- **Syntax checking**: `swiftc -parse <file.swift>` validates Swift syntax without macOS SDK imports
- **Project structure validation**: Inspecting `project.yml`, entitlements, Info.plist

### Running SwiftLint (lint checks)

```bash
export LINUX_SOURCEKIT_LIB_PATH=/home/ubuntu/.local/share/swiftly/toolchains/6.3.2/usr/lib
source "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
cd /workspace
swiftlint lint
```

The project has no `.swiftlint.yml` — defaults are used. Currently reports ~90 violations (style warnings in existing code — not blocking).

### Swift Syntax Parsing

To verify Swift syntax is valid without needing macOS SDK:

```bash
source "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
swiftc -parse ClipStack/path/to/file.swift
```

This validates syntax (parsing) but cannot type-check since macOS frameworks (AppKit, ScreenCaptureKit, SwiftUI, etc.) are unavailable on Linux.

### Building and Running (macOS only)

See the workspace rule in `.cursor/rules/rebuild-and-launch.mdc` for the authoritative build/launch workflow. Key points:

- Always use `./scripts/rebuild-and-run.sh` to build, install, and launch
- Never launch via `open` directly or Xcode's Run button (TCC attribution issues)
- The app installs to `~/Applications/ClipStack.app`
- Build logs go to `build/rebuild.log`

### Key Dependencies (resolved automatically by xcodebuild)

- **KeyboardShortcuts** (≥2.2.0) — global hotkey registration
- **Sparkle** (≥2.6.0) — auto-update framework

### No Tests

The project currently has no automated test target. Testing on Linux is limited to linting and syntax validation.
