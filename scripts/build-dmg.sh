#!/usr/bin/env bash
set -euo pipefail

# Builds a signed Release .app and packages dist/Polished-<version>.dmg plus dist/Polished.dmg.
#
# Uses the Xcode project's Automatic code signing so TCC permissions (Accessibility,
# Input Monitoring, Automation) persist when updating by replacing the app in Applications.
# Override with CODE_SIGN_IDENTITY / CODE_SIGNING_ALLOWED env vars if needed.
#
# DMG layout: Polished.app on the left, Applications symlink on the right.
# When create-dmg is installed (brew install create-dmg), uses it for icon positions
# and a clean window. Otherwise falls back to hdiutil + AppleScript to set Finder
# view options (icon view, window size, icon positions) on the mounted volume.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="Polished"
CONFIG="Release"
DERIVED="$ROOT/.derivedData"
DIST="$ROOT/dist"
APP_NAME="Polished"
STAGING="$DIST/dmg-staging"
MOUNT="/Volumes/${APP_NAME}"

cd "$ROOT"

echo "Building ${APP_NAME} (${CONFIG})…"
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  build

APP_PATH="$DERIVED/Build/Products/${CONFIG}/${APP_NAME}.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app not found at $APP_PATH" >&2
  exit 1
fi

if ! codesign --verify --deep --strict "$APP_PATH" 2>/dev/null; then
  echo "warning: app is not signed; privacy permissions may reset on each update" >&2
  echo "         grant signing access in Xcode or set CODE_SIGN_IDENTITY for xcodebuild" >&2
else
  echo "Code signature:"
  codesign -dv "$APP_PATH" 2>&1 | grep -E 'Authority|TeamIdentifier' || true
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="$DIST/${DMG_NAME}"

rm -rf "$STAGING" "$DIST/${APP_NAME}.dmg" "$DMG_PATH"
mkdir -p "$STAGING" "$DIST"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

if command -v create-dmg >/dev/null 2>&1; then
  echo "Creating DMG with create-dmg…"
  create-dmg \
    --volname "$APP_NAME" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 128 \
    --icon "${APP_NAME}.app" 180 190 \
    --hide-extension "${APP_NAME}.app" \
    --app-drop-link 480 190 \
    "$DMG_PATH" \
    "$STAGING"
else
  echo "Creating DMG (hdiutil + Finder layout)…"
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

  echo "Applying Finder window layout…"
  hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
  if hdiutil attach "$DMG_PATH" -readwrite -noverify -noautoopen -quiet; then
    if ! osascript <<EOF
tell application "Finder"
  set targetFolder to disk "$APP_NAME"
  open targetFolder
  set dmgWindow to container window of targetFolder
  tell dmgWindow
    set current view to icon view
    set toolbar visible to false
    set statusbar visible to false
    set bounds to {200, 120, 860, 520}
  end tell
  tell icon view options of dmgWindow
    set icon size to 128
    set arrangement to not arranged
  end tell
  set position of item "${APP_NAME}.app" of dmgWindow to {180, 190}
  set position of item "Applications" of dmgWindow to {480, 190}
  close dmgWindow
  open dmgWindow
  update without registering applications
  delay 2
  close dmgWindow
end tell
EOF
    then
      echo "warning: Finder layout step failed; DMG is still valid without custom icon positions" >&2
    fi
    hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
  else
    echo "warning: could not attach DMG for layout; skipping Finder customization" >&2
  fi
fi

cp "$DMG_PATH" "$DIST/${APP_NAME}.dmg"
rm -rf "$STAGING"

echo "Done: $DIST/${APP_NAME}.dmg"
