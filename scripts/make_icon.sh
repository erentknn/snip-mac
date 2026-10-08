#!/bin/bash
# Regenerates Resources/AppIcon.icns from scripts/make_icon.swift.
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
rm -rf "$work"
echo "Wrote Resources/AppIcon.icns"
