#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DERIVED_DATA="$ROOT/build/DerivedData"
BUILD_APP="$DERIVED_DATA/Build/Products/Debug/ClipStack.app"
INSTALL_APP="$HOME/Applications/ClipStack.app"
LOG="$ROOT/build/rebuild.log"

mkdir -p "$ROOT/build" "$HOME/Applications"

quit_clipstack() {
  echo "[ClipStack] Quitting running instances…"
  pkill -x ClipStack 2>/dev/null || true
  sleep 0.5

  local attempts=0
  while pgrep -x ClipStack >/dev/null && [[ $attempts -lt 20 ]]; do
    sleep 0.2
    attempts=$((attempts + 1))
  done

  if pgrep -x ClipStack >/dev/null; then
    echo "[ClipStack] Force quitting remaining instances…"
    pkill -9 -x ClipStack 2>/dev/null || true
    sleep 0.3
  fi
}

quit_clipstack

# Nuke any stray Xcode DerivedData copies of ClipStack. If left in place,
# hitting Run in Xcode (or any tool that runs `xcodebuild build` without
# `-derivedDataPath`) can produce an ad-hoc-signed binary there. LaunchServices
# treats both bundles as "the same app" by bundle ID, so a stale DerivedData
# copy can end up running instead of ~/Applications/ClipStack.app — and
# because its code identity differs, TCC re-prompts for every permission.
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
XCODE_DERIVED="$HOME/Library/Developer/Xcode/DerivedData"
if [[ -d "$XCODE_DERIVED" ]]; then
  find "$XCODE_DERIVED" -maxdepth 1 -type d -name "ClipStack-*" -print0 2>/dev/null | \
    while IFS= read -r -d '' stray; do
      # Unregister any .app inside this DerivedData folder from LaunchServices
      # before deleting it, so LS doesn't keep a dangling reference that could
      # later resolve `open com.theorichardson.ClipStack` to the deleted path.
      find "$stray" -type d -name "ClipStack.app" -print0 2>/dev/null | \
        while IFS= read -r -d '' app; do
          [[ -x "$LSREG" ]] && "$LSREG" -u "$app" 2>/dev/null || true
        done
      echo "[ClipStack] Removing stray Xcode build dir: $stray"
      rm -rf "$stray"
    done
fi

if command -v xcodegen >/dev/null; then
  echo "[ClipStack] Running xcodegen…"
  xcodegen generate
fi

echo "[ClipStack] Building…"
xcodebuild \
  -scheme ClipStack \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  build >"$LOG" 2>&1

echo "[ClipStack] Installing to $INSTALL_APP"
rm -rf "$INSTALL_APP"
ditto "$BUILD_APP" "$INSTALL_APP"

SIGN_IDENTITY="Apple Development: Theodore Richardson (Z7APD9TUWA)"
ENTITLEMENTS="$ROOT/ClipStack/ClipStack.entitlements"
if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
  echo "[ClipStack] Signing with development certificate…"
  # Sign embedded frameworks first (inside-out), without entitlements, then the app.
  # Avoid --deep: it's deprecated and re-applies the app's entitlements to nested
  # binaries, which TCC notices as identity churn and which corrupts framework
  # designated requirements (this app stops being seen as the same client by
  # TCC, so a permission granted in System Settings can appear to not apply).
  if [[ -d "$INSTALL_APP/Contents/Frameworks" ]]; then
    find "$INSTALL_APP/Contents/Frameworks" -type d -name "*.framework" -print0 | \
      while IFS= read -r -d '' fw; do
        echo "[ClipStack] Signing framework: $(basename "$fw")"
        codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none "$fw"
      done
  fi
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none \
    --entitlements "$ENTITLEMENTS" "$INSTALL_APP"
  echo "[ClipStack] Verifying signature…"
  codesign --verify --verbose=2 "$INSTALL_APP" || {
    echo "[ClipStack] Signature verification failed" >&2
    exit 1
  }
else
  echo "[ClipStack] Warning: development certificate not found; using adhoc signature"
  codesign --force --sign - --options runtime --timestamp=none \
    --entitlements "$ENTITLEMENTS" "$INSTALL_APP"
fi

quit_clipstack

# Register the installed copy with LaunchServices so any future `open
# com.theorichardson.ClipStack` (or any tool that resolves by bundle ID)
# resolves to ~/Applications/ClipStack.app and not a stale Xcode build.
if [[ -x "$LSREG" ]]; then
  "$LSREG" -f "$INSTALL_APP" 2>/dev/null || true
fi

# Launch via `launchctl asuser` + `open -n`. This is CRITICAL for TCC.
#
# macOS attributes Screen Recording / Accessibility / Clipboard requests to
# the "responsible process", which it computes by walking up the launching
# process tree. If we exec the binary directly from this shell, ClipStack's
# parent is the shell, whose parent is Cursor (or Terminal/Xcode/etc), so
# TCC decides Cursor is responsible — and then prompts the user for *Cursor*
# rather than ClipStack, or silently denies if Cursor's toggle is off.
# ClipStack never appears as a row in System Settings → Screen Recording.
#
# Routing through `launchctl asuser $UID open` re-roots the launch under
# launchd: launchd becomes ClipStack's effective parent, and ClipStack
# itself becomes its own responsible process. Now TCC prompts for ClipStack
# and adds it to the Screen Recording / Accessibility lists.
#
# `open -n` forces a new instance at the explicit path passed in (so
# LaunchServices does not substitute a different cached bundle ID copy).
echo "[ClipStack] Launching $INSTALL_APP via launchd"
launchctl asuser "$(id -u)" /usr/bin/open -n "$INSTALL_APP"

echo "[ClipStack] Done. Build log: $LOG"
