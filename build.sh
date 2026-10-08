#!/bin/bash
# Builds Snip.app into ./build. Pass --install to copy it to /Applications and launch it.
# Signs with your first "Apple Development" certificate so macOS keeps the Screen Recording
# permission across rebuilds (ad-hoc signatures change every build). Override with SIGN_IDENTITY.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Snip.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Snip "$APP/Contents/MacOS/Snip"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "warning: no Apple Development certificate found; ad-hoc signing (permissions reset on every rebuild)"
    SIGN_IDENTITY=-
fi
codesign --force --sign "$SIGN_IDENTITY" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Snip || true
    rm -rf /Applications/Snip.app
    cp -R "$APP" /Applications/
    open /Applications/Snip.app
    echo "Installed to /Applications/Snip.app"
fi
