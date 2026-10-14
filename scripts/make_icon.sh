#!/bin/bash
# Regenerates the app icon from scripts/make_icon.swift:
#   Resources/AppIcon.icns                          used by the SwiftPM builds (build.sh, release.sh)
#   Resources/Assets.xcassets/AppIcon.appiconset    used by the Xcode/App Store build
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
swift scripts/make_icon.swift "$work/icon.png"
iconset="$work/AppIcon.iconset"
mkdir "$iconset"
for s in 16 32 128 256 512; do
    sips -z $s $s "$work/icon.png" --out "$iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$work/icon.png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o Resources/AppIcon.icns

catalog=Resources/Assets.xcassets
appiconset=$catalog/AppIcon.appiconset
rm -rf "$appiconset"
mkdir -p "$appiconset"
cp "$iconset"/*.png "$appiconset/"
echo '{ "info" : { "author" : "xcode", "version" : 1 } }' > "$catalog/Contents.json"
{
    echo '{ "images" : ['
    sep=""
    for s in 16 32 128 256 512; do
        for scale in 1 2; do
            file="icon_${s}x${s}.png"; [[ $scale == 2 ]] && file="icon_${s}x${s}@2x.png"
            printf '%s\n    { "idiom" : "mac", "size" : "%sx%s", "scale" : "%sx", "filename" : "%s" }' \
                "$sep" "$s" "$s" "$scale" "$file"
            sep=","
        done
    done
    echo
    echo '  ], "info" : { "author" : "xcode", "version" : 1 } }'
} > "$appiconset/Contents.json"

rm -rf "$work"
echo "Wrote Resources/AppIcon.icns and $appiconset"
