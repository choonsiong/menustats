#!/bin/bash
# Builds MenuStats.app from the Swift package.
#   ./build.sh            build only
#   ./build.sh --install  build, copy to /Applications, and launch

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MenuStats"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"

echo "==> Compiling (release)"
swift build -c release --disable-sandbox

echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP_BUNDLE"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to /Applications"
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/$APP_BUNDLE"
    cp -R "$APP_BUNDLE" /Applications/
    open "/Applications/$APP_BUNDLE"
    echo "==> Running. Look at the right side of your menu bar."
else
    echo "==> Done. Run it with:  open $APP_BUNDLE"
fi
