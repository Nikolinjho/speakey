#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v rsvg-convert >/dev/null || { echo 'Нужен rsvg-convert (librsvg)' >&2; exit 1; }
work="$(mktemp -d /private/tmp/speakey-icon.XXXXXX)"
trap 'rm -rf "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    rsvg-convert -w "$size" -h "$size" Resources/AppIcon.svg -o "$iconset/icon_${size}x${size}.png"
    retina=$((size * 2))
    rsvg-convert -w "$retina" -h "$retina" Resources/AppIcon.svg -o "$iconset/icon_${size}x${size}@2x.png"
done
iconutil --convert icns "$iconset" --output "$work/AppIcon.icns"
cp "$work/AppIcon.icns" Resources/AppIcon.icns
printf 'Готово: Resources/AppIcon.icns, 10 размеров из SVG\n'
