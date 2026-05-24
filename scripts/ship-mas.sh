#!/usr/bin/env bash
# Archive ClipStack and upload to App Store Connect for TestFlight / Mac App Store review.
#
# Prereqs (one-time):
#   1) Sign in to Xcode > Settings > Accounts with the Apple ID for team Z7APD9TUWA.
#   2) In Xcode, open ClipStack.xcodeproj, select the ClipStack target, Signing & Capabilities:
#      confirm "Automatically manage signing" is on and team is selected.
#   3) Create the app record in App Store Connect:
#        - Platform: macOS
#        - Bundle ID: com.theorichardson.ClipStack  (register on developer.apple.com first)
#        - SKU: clipstack
#        - Primary language: English (U.S.)
#   4) Create an App Store Connect API key (Users and Access > Integrations > App Store Connect API):
#        - Role: App Manager
#        - Download the .p8 once, note Key ID and Issuer ID
#        - Save the key at: ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
#        - Export env vars before running this script:
#            export ASC_KEY_ID=XXXXXXXXXX
#            export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#
# Usage:
#   scripts/ship-mas.sh                # archive + upload
#   scripts/ship-mas.sh archive-only   # just build the archive
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="ClipStack"
TEAM_ID="YW3FCY33TJ"
ARCHIVE_PATH="$PWD/build/ClipStack.xcarchive"
EXPORT_DIR="$PWD/build/export"

xcodegen generate

echo "==> Bumping build number to $(date +%s)"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

echo "==> Archiving (Release, App Store distribution)"
xcodebuild \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  archive

if [[ "${1:-}" == "archive-only" ]]; then
  echo "Archive at $ARCHIVE_PATH"
  exit 0
fi

echo "==> Exporting + uploading to App Store Connect"
rm -rf "$EXPORT_DIR"

EXPORT_ARGS=(
  -exportArchive
  -archivePath "$ARCHIVE_PATH"
  -exportOptionsPlist ExportOptions.plist
  -exportPath "$EXPORT_DIR"
  -allowProvisioningUpdates
)

if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  EXPORT_ARGS+=(
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
    -authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
  )
fi

xcodebuild "${EXPORT_ARGS[@]}"

echo "==> Done. Build $BUILD_NUMBER uploaded. Check App Store Connect > TestFlight in ~5-15 min."
