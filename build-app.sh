#!/bin/zsh
# Builds "Greycard.app" and an installer DMG into ./build.
# Needs Xcode or the Command Line Tools (xcode-select --install).
#
#   ./build-app.sh            build app + DMG
#   ./build-app.sh --install  also copy into /Applications and launch it
set -euo pipefail
cd "$(dirname "$0")"

NAME="Greycard"
APP="build/$NAME.app"
DMG="build/Greycard.dmg"

echo "→ Compiling (release)…"
swift build -c release

echo "→ Assembling $NAME.app…"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Greycard "$APP/Contents/MacOS/Greycard"
cp Info.plist "$APP/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: required for Apple Silicon, free, no Apple Developer account needed.
codesign --force --deep --sign - "$APP"

echo "→ Creating DMG…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo ""
echo "Built:  $(pwd)/$APP"
echo "        $(pwd)/$DMG   (open it and drag the app onto Applications)"
echo "Diagnostics (changes nothing):  \"$APP/Contents/MacOS/Greycard\" --doctor"

if [[ "${1:-}" == "--install" ]]; then
  echo "→ Installing to /Applications…"
  pkill -x Greycard 2>/dev/null || true
  rm -rf "/Applications/$NAME.app"
  cp -R "$APP" /Applications/
  open "/Applications/$NAME.app"
  echo "Installed. Look for the display icon in the menu bar."
fi
