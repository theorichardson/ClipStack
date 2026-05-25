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

echo "[ClipStack] Launching $INSTALL_APP"
open "$INSTALL_APP"

echo "[ClipStack] Done. Build log: $LOG"
