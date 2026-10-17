#!/bin/zsh
# Builds Leap.app. Usage: ./build.sh [--install]   (--install copies to /Applications and relaunches)
set -euo pipefail
cd "${0:A:h}"

swift build -c release --arch arm64
APP=build/Leap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Leap "$APP/Contents/MacOS/Leap"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Sign with a stable identity so macOS keeps the Accessibility/Screen Recording grants across rebuilds.
IDENTITY=${LEAP_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}
if [[ -z "$IDENTITY" ]]; then
  echo "warning: no signing identity found, ad-hoc signing (permissions reset on every build)"
  IDENTITY=-
fi
codesign --force --sign "$IDENTITY" "$APP"
echo "built $APP (signed: $IDENTITY)"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Leap || true
  rm -rf /Applications/Leap.app
  cp -R "$APP" /Applications/
  open /Applications/Leap.app
  echo "installed /Applications/Leap.app"
fi
