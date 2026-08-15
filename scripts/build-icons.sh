#!/usr/bin/env bash
# Regenerate AppIcon.icns and the menu-bar template PNGs from the SVG
# sources under Sources/DshDesktop/Resources/.
#
# Requirements: qlmanage (macOS native, system fonts via Quick Look),
#               sips (macOS native), iconutil (macOS native).
#
# Output:
#   Sources/DshDesktop/Resources/AppIcon.icns
#   Sources/DshDesktop/Resources/MenuBarIconTemplate.png      (19x19)
#   Sources/DshDesktop/Resources/MenuBarIconTemplate@2x.png   (38x38)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RES="$ROOT/Sources/DshDesktop/Resources"
TMP="$(mktemp -d -t dsh-icons)"
trap 'rm -rf "$TMP"' EXIT

APP_SVG="$RES/AppIcon.svg"
MENU_SVG="$RES/MenuBarIconTemplate.svg"

test -f "$APP_SVG"  || { echo "missing $APP_SVG"; exit 1; }
test -f "$MENU_SVG" || { echo "missing $MENU_SVG"; exit 1; }

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

echo "==> rendering 1024px master via qlmanage (system fonts)"
qlmanage -t -s 1024 -o "$ICONSET" "$APP_SVG" >/dev/null 2>&1
mv "$ICONSET/AppIcon.svg.png" "$ICONSET/_1024.png"

echo "==> resizing to all 10 .icns sizes via sips"
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
            "512 icon_256x256@2x" "512 icon_512x512"; do
  size=${spec% *}; name=${spec#* }
  sips -z "$size" "$size" "$ICONSET/_1024.png" --out "$ICONSET/$name.png" >/dev/null
done
cp "$ICONSET/_1024.png" "$ICONSET/icon_512x512@2x.png"

echo "==> building AppIcon.icns"
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"

echo "==> rendering menu-bar template (38px @2x)"
qlmanage -t -s 38 -o "$TMP" "$MENU_SVG" >/dev/null 2>&1
cp "$TMP/MenuBarIconTemplate.svg.png" "$RES/MenuBarIconTemplate@2x.png"
sips -z 19 19 "$TMP/MenuBarIconTemplate.svg.png" --out "$RES/MenuBarIconTemplate.png" >/dev/null

echo "==> done"
ls -la "$RES/AppIcon.icns" "$RES/MenuBarIconTemplate.png" "$RES/MenuBarIconTemplate@2x.png"