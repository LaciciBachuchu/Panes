#!/bin/bash
# Builds Panes.app into ./build. Usage: Scripts/build_app.sh [--install]
#   --install  copies the app to /Applications and relaunches it.
# Signs with the "Panes Local Signing" certificate when it exists (or PANES_SIGN_ID),
# which keeps the Accessibility grant across rebuilds; otherwise ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Panes"

APP=build/Panes.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Panes"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
    swift Scripts/make_icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Prefer the local "Panes Local Signing" certificate so the Accessibility grant survives rebuilds.
if [ -z "${PANES_SIGN_ID:-}" ] && security find-identity -p codesigning | grep -q "Panes Local Signing"; then
    PANES_SIGN_ID="Panes Local Signing"
fi
codesign --force --deep --options runtime --sign "${PANES_SIGN_ID:--}" "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    pkill -x Panes || true
    rm -rf /Applications/Panes.app
    cp -R "$APP" /Applications/
    open /Applications/Panes.app
    echo "Installed to /Applications/Panes.app"
fi
