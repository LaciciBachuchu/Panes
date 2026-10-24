#!/bin/bash
# Builds Panes.app into ./build. Usage: Scripts/build_app.sh [--install | --release]
#   --install  copies the app to /Applications and relaunches it.
#   --release  builds a universal (Apple silicon + Intel) app and zips it to build/Panes.zip.
# Signs with the "Panes Local Signing" certificate when it exists (or PANES_SIGN_ID),
# which keeps the Accessibility grant across rebuilds; otherwise ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH_ARGS=()
[ "${1:-}" = "--release" ] && ARCH_ARGS=(--arch arm64 --arch x86_64)
swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN="$(swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)/Panes"

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
    # Wait for the old instance to exit, or `open` may just re-activate it.
    for _ in $(seq 50); do pgrep -x Panes >/dev/null || break; sleep 0.1; done
    rm -rf /Applications/Panes.app
    cp -R "$APP" /Applications/
    open /Applications/Panes.app
    echo "Installed to /Applications/Panes.app"
fi

if [ "${1:-}" = "--release" ]; then
    rm -f build/Panes.zip
    ditto -c -k --keepParent "$APP" build/Panes.zip
    echo "Release zip: build/Panes.zip"
fi
