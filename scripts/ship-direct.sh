#!/usr/bin/env bash
# Build, sign, notarize, and stage a Developer ID release of ClipStack for
# direct distribution via GitHub Pages + GitHub Releases.
#
# One-time prereqs:
#   1) Developer ID Application cert in your login keychain
#      (Xcode > Settings > Accounts > Manage Certificates > + > Developer ID).
#   2) App-specific password for notarytool:
#        xcrun notarytool store-credentials ClipStackNotary \
#          --apple-id <your-apple-id> \
#          --team-id YW3FCY33TJ \
#          --password <app-specific-password>
#   3) Sparkle EdDSA key pair (run once, after first xcodegen + Xcode resolves
#      Sparkle SwiftPM artifacts so `generate_keys` is available):
#        BIN_DIR="$(find ~/Library/Developer/Xcode/DerivedData ./build \
#          -type d -name 'Sparkle' 2>/dev/null \
#          -exec find {} -type f -name generate_keys \; | head -1)"
#        "$BIN_DIR" --account ClipStack
#      Then paste the printed public key into project.yml SUPublicEDKey and
#      re-run xcodegen. The private key stays in your login keychain.
#   4) gh CLI authenticated: gh auth status (must show theorichardson logged in).
#
# Usage:
#   scripts/ship-direct.sh                  # build, sign, notarize, draft release
#   scripts/ship-direct.sh --skip-notarize  # build + dmg only (smoke test)
set -euo pipefail

cd "$(dirname "$0")/.."

REPO_OWNER="theorichardson"
REPO_NAME="ClipStack"
TEAM_ID="YW3FCY33TJ"
NOTARY_PROFILE="ClipStackNotary"
SPARKLE_ACCOUNT="ClipStack"

SCHEME="ClipStack"
BUILD_DIR="$PWD/build"
ARCHIVE_PATH="$BUILD_DIR/ClipStack.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_DIR="$BUILD_DIR/dmg"

SKIP_NOTARIZE=0
if [[ "${1:-}" == "--skip-notarize" ]]; then
  SKIP_NOTARIZE=1
fi

echo "==> xcodegen"
xcodegen generate

VERSION="$(awk '/MARKETING_VERSION:/ {gsub(/"/,"",$2); print $2; exit}' project.yml)"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
DMG_NAME="ClipStack-$VERSION.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

echo "==> Version: $VERSION (build $BUILD_NUMBER)"

echo "==> Archiving (Release, Developer ID)"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$DMG_DIR" "$DMG_PATH"
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

echo "==> Exporting Developer-ID-signed .app"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates

APP_PATH="$EXPORT_DIR/ClipStack.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: $APP_PATH missing after export" >&2
  exit 1
fi

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl -a -vvv -t install "$APP_PATH" || true

echo "==> Building DMG: $DMG_NAME"
mkdir -p "$DMG_DIR"
cp -R "$APP_PATH" "$DMG_DIR/ClipStack.app"
ln -s /Applications "$DMG_DIR/Applications"

# Generate the install-window background (arrow between app and Applications).
mkdir -p "$DMG_DIR/.background"
BG_PATH="$DMG_DIR/.background/background.png"
swift - "$BG_PATH" <<'SWIFT'
import AppKit

let outPath = CommandLine.arguments[1]
let width = 660
let height = 400

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { fatalError("rep create failed") }
rep.size = NSSize(width: width, height: height)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()

let arrowColor = NSColor(calibratedWhite: 0.70, alpha: 1)
arrowColor.setStroke()
arrowColor.setFill()

let midY: CGFloat = CGFloat(height) / 2
let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: 260, y: midY))
shaft.line(to: NSPoint(x: 395, y: midY))
shaft.lineWidth = 6
shaft.lineCapStyle = .round
shaft.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: 415, y: midY))
head.line(to: NSPoint(x: 388, y: midY + 18))
head.line(to: NSPoint(x: 388, y: midY - 18))
head.close()
head.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("png encode failed")
}
try png.write(to: URL(fileURLWithPath: outPath))
SWIFT

# Build a writable DMG so we can set Finder view options, then convert to UDZO.
RW_DMG="$BUILD_DIR/ClipStack-rw.dmg"
VOL_NAME="ClipStack $VERSION"
rm -f "$RW_DMG"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$DMG_DIR" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$RW_DMG"

echo "==> Applying Finder layout"
MOUNT_OUT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)"
DEVICE="$(echo "$MOUNT_OUT" | awk 'NR==1 {print $1}')"
MOUNT_POINT="/Volumes/$VOL_NAME"

# Give Finder a moment to register the volume before scripting it.
sleep 2

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 520}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.png"
        set position of item "ClipStack.app" of container window to {170, 200}
        set position of item "Applications" of container window to {490, 200}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$DEVICE" -quiet || hdiutil detach "$DEVICE" -force

echo "==> Converting to compressed DMG"
rm -f "$DMG_PATH"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
rm -f "$RW_DMG"

echo "==> Signing DMG with Developer ID"
codesign --sign "Developer ID Application" --timestamp "$DMG_PATH"

if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
  echo "==> Skipping notarization (smoke test)"
  echo "DMG at $DMG_PATH"
  exit 0
fi

echo "==> Submitting to Apple notary service (this can take 1-15 min)"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl -a -vvv -t install "$DMG_PATH"

echo "==> Computing Sparkle EdDSA signature"
SIGN_UPDATE="$(find "$HOME/Library/Developer/Xcode/DerivedData" "$BUILD_DIR" \
  -type f -name sign_update 2>/dev/null | head -1)"
if [[ -z "$SIGN_UPDATE" ]]; then
  echo "WARNING: sign_update not found; skipping appcast update." >&2
  echo "Resolve Sparkle in Xcode at least once, then re-run." >&2
else
  SPARKLE_SIG_LINE="$("$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$DMG_PATH")"
  echo "    $SPARKLE_SIG_LINE"
fi

DMG_SIZE="$(stat -f%z "$DMG_PATH")"
RELEASE_TAG="v$VERSION"
RELEASE_URL="https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/$RELEASE_TAG/$DMG_NAME"
PUB_DATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"

echo "==> Creating draft GitHub release $RELEASE_TAG"
if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
  echo "Release $RELEASE_TAG already exists; uploading asset (clobber)."
  gh release upload "$RELEASE_TAG" "$DMG_PATH" --clobber
else
  gh release create "$RELEASE_TAG" "$DMG_PATH" \
    --draft \
    --title "ClipStack $VERSION" \
    --notes "ClipStack $VERSION — see CHANGELOG."
fi

echo "==> Appending <item> to docs/appcast.xml"
APPCAST="docs/appcast.xml"
if [[ -n "${SPARKLE_SIG_LINE:-}" ]]; then
  ITEM_BLOCK=$(cat <<EOF
        <item>
            <title>ClipStack $VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$BUILD_NUMBER</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="$RELEASE_URL" type="application/octet-stream" $SPARKLE_SIG_LINE />
        </item>
EOF
)
  python3 - "$APPCAST" "$ITEM_BLOCK" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
item = sys.argv[2]
text = path.read_text()
marker = "        <!-- NEW_ITEMS_ABOVE -->"
if marker not in text:
    raise SystemExit(f"Marker {marker!r} not found in {path}")
text = text.replace(marker, item + "\n" + marker, 1)
path.write_text(text)
print(f"Updated {path}")
PY
fi

cat <<EOF

==> Done.

Notarized DMG:     $DMG_PATH
Sparkle signature: ${SPARKLE_SIG_LINE:-<missing — appcast not updated>}
Draft release:     https://github.com/$REPO_OWNER/$REPO_NAME/releases/tag/$RELEASE_TAG

Next steps:
  1) Test the DMG locally:
       open "$DMG_PATH"
     Drag ClipStack to /Applications, launch, verify Gatekeeper accepts it.
  2) Publish the GitHub release (flips draft -> public):
       gh release edit $RELEASE_TAG --draft=false
  3) Commit and push the updated appcast:
       git add docs/appcast.xml
       git commit -m "Release $VERSION"
       git push
  4) GitHub Pages will redeploy in ~30s. Verify:
       https://$REPO_OWNER.github.io/$REPO_NAME/
EOF
