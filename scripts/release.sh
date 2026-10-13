#!/bin/zsh
# Builds a signed, notarized Compositor DMG that opens without warnings on any Mac.
#
# Needs, all kept out of this repository:
#   - a "Developer ID Application" certificate in the login keychain
#   - notarization credentials saved once with:
#       xcrun notarytool store-credentials "compositor-notary" --apple-id "…" --team-id 3E4X3B9Z9T
#   - create-dmg (brew install create-dmg)
# The DMG window background is scripts/dmg/dmg-bg.jpg (600 × 380, the window's exact size) plus
# dmg-bg-retina.jpg (1200 × 760) for Retina displays.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP=Compositor
TEAM=3E4X3B9Z9T
IDENTITY="Developer ID Application"
NOTARY_PROFILE=compositor-notary
# Built outside Dropbox: the extended attributes it adds to files make code signing fail.
WORK="$HOME/Library/Caches/CompositorRelease"
DIST="$PROJECT_DIR/dist"

settings=$(xcodebuild -project "$PROJECT_DIR/$APP.xcodeproj" -scheme "$APP" -configuration Release -showBuildSettings 2>/dev/null)
VERSION=$(print -r -- "$settings" | awk -F' = ' '/ MARKETING_VERSION = /{print $2; exit}')
BUILD=$(print -r -- "$settings" | awk -F' = ' '/ CURRENT_PROJECT_VERSION = /{print $2; exit}')
echo "==> $APP $VERSION ($BUILD)"

# What this DMG is built from, recorded beside it so publish.sh can refuse a DMG that isn't the commit it's
# about to tag. Uncommitted changes are built (handy for a trial run) but such a DMG can't be published.
COMMIT=$(git -C "$PROJECT_DIR" rev-parse HEAD)
DIRTY=no
if [[ -n "$(git -C "$PROJECT_DIR" status --porcelain)" ]]; then
  DIRTY=yes
  echo "==> Warning: the working tree has uncommitted changes; publish.sh will refuse this build"
fi

# Nothing gets signed and notarized unless it builds cleanly and its tests pass.
# SKIP_CI=1 skips this for a build whose exact commit already passed.
CI=skipped
if [[ "${SKIP_CI:-}" != 1 ]]; then
  "$PROJECT_DIR/scripts/ci.sh"
  CI=passed
fi

rm -rf "$WORK"
mkdir -p "$WORK" "$DIST"
# Written again only once the DMG is signed, notarized and stapled, so a failed run leaves nothing publishable.
rm -f "$DIST/$APP-$VERSION.build-info"

echo "==> Archiving a Release build"
xcodebuild archive -quiet \
  -project "$PROJECT_DIR/$APP.xcodeproj" -scheme "$APP" -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$WORK/$APP.xcarchive" -derivedDataPath "$WORK/DerivedData" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM"

echo "==> Exporting, signed with Developer ID"
xcodebuild -exportArchive -quiet \
  -archivePath "$WORK/$APP.xcarchive" \
  -exportOptionsPlist "$PROJECT_DIR/scripts/ExportOptions.plist" \
  -exportPath "$WORK/export"
APP_PATH="$WORK/export/$APP.app"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Notarizing the app"
ditto -c -k --keepParent "$APP_PATH" "$WORK/$APP.zip"
xcrun notarytool submit "$WORK/$APP.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"

echo "==> Building the DMG window"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
cp -R "$APP_PATH" "$STAGE/"
DMG="$DIST/$APP-$VERSION.dmg"
rm -f "$DMG"
# Icon centers in the DMG window, in points from its top-left.
APP_X=160
APPLICATIONS_X=440
ICON_Y=180
background=()
LOW="$PROJECT_DIR/scripts/dmg/dmg-bg.jpg"
HIGH="$PROJECT_DIR/scripts/dmg/dmg-bg-retina.jpg"
if [[ -f "$LOW" && -f "$HIGH" ]]; then
  # Finder takes one background file; a TIFF holding both sizes stays sharp on Retina displays.
  sips -s format png -s dpiWidth 72 -s dpiHeight 72 "$LOW" --out "$WORK/background.png" >/dev/null
  sips -s format png -s dpiWidth 144 -s dpiHeight 144 "$HIGH" --out "$WORK/background@2x.png" >/dev/null
  tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" >/dev/null
  background=(--background "$WORK/background.tiff")
elif [[ -f "$LOW" ]]; then
  background=(--background "$LOW")
fi
create-dmg \
  --volname "$APP" \
  --window-pos 200 120 --window-size 600 380 \
  --icon-size 128 --text-size 13 \
  --icon "$APP.app" "$APP_X" "$ICON_Y" --hide-extension "$APP.app" \
  --app-drop-link "$APPLICATIONS_X" "$ICON_Y" \
  "${background[@]}" \
  "$DMG" "$STAGE"

echo "==> Signing and notarizing the DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> What Gatekeeper will say on another Mac"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
spctl --assess --type execute --verbose=2 "$APP_PATH"
print -r -- "commit=$COMMIT
dirty=$DIRTY
ci=$CI" > "$DIST/$APP-$VERSION.build-info"
echo "==> SHA-256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "==> Done: $DMG"
