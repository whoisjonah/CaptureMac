#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
source="Branding/Exports/AppIcon-1024.png"
iconset=$(mktemp -d)/AppIcon.iconset
mkdir -p "$iconset"

for size in 16 32 128 256 512; do
  sips -z $size $size "$source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset" -o Resources/AppIcon.icns
rm -rf "$(dirname "$iconset")"
echo "icon updated"
