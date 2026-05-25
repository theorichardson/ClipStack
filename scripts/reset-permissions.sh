#!/bin/bash
# Reset macOS Screen Recording, Accessibility, and Clipboard TCC entries for ClipStack.
#
# Use this when System Settings shows the permission as "on" but the running
# app cannot actually capture the screen / read the clipboard / drive
# Accessibility. That symptom almost always means TCC has multiple stale rows
# for old code identities (e.g. previous ad-hoc Xcode build vs. the current
# developer-signed build, or an old path under DerivedData vs. the current
# install at ~/Applications).
#
# After running this script:
#   1. Quit ClipStack (`pkill -x ClipStack`)
#   2. Re-launch (`./scripts/rebuild-and-run.sh`)
#   3. Approve the system prompts when they appear. Granted entries will now
#      bind to the current code identity only.
set -euo pipefail

BUNDLE_ID="com.theorichardson.ClipStack"

echo "[ClipStack] Quitting any running instances…"
pkill -x ClipStack 2>/dev/null || true
sleep 0.3

echo "[ClipStack] Resetting Screen Recording TCC entries for $BUNDLE_ID"
tccutil reset ScreenCapture "$BUNDLE_ID" || true

echo "[ClipStack] Resetting Accessibility TCC entries for $BUNDLE_ID"
tccutil reset Accessibility "$BUNDLE_ID" || true

echo "[ClipStack] Resetting Clipboard (Pasteboard) TCC entries for $BUNDLE_ID"
tccutil reset Pasteboard "$BUNDLE_ID" || true

echo "[ClipStack] Done. Re-launch with ./scripts/rebuild-and-run.sh and accept the prompts."
