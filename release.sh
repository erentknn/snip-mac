#!/bin/bash
# Builds a signed, notarized Snip-<version>.dmg (Apple Silicon + Intel) into ./dist.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
PROFILE=${NOTARY_PROFILE:-snip}
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}
if [[ -z "$IDENTITY" ]]; then
    echo "error: no Developer ID Application certificate found" >&2
    exit 1
fi

DIST=dist
APP=$DIST/Snip.app
DMG=$DIST/Snip-$VERSION.dmg
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Building universal binary"
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
cp "$BIN/Snip" "$APP/Contents/MacOS/Snip"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing with $IDENTITY"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Notarizing the app"
ditto -c -k --keepParent "$APP" "$DIST/Snip.zip"
xcrun notarytool submit "$DIST/Snip.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$DIST/Snip.zip"

echo "==> Building the disk image"
STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Snip $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "==> Notarizing the disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "Built $DMG"

if [[ "${1:-}" == "--publish" ]]; then
    gh release create "v$VERSION" "$DMG" --title "Snip $VERSION" --generate-notes
fi
