#!/usr/bin/env bash
# Build a distributable DMG from the .app produced by bundle.sh + sign.sh.
#
# Output: build/DshDesktop-<version>.dmg
# Format: UDZO (compressed read-only) with an Applications symlink for
#         drag-to-install UX.
# Signing: ad-hoc (matches the .app). Replace `-` with a Developer ID
#          for notarized distribution.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/DshDesktop.app"
test -d "$APP" || { echo "no $APP — run ./scripts/bundle.sh && ./scripts/sign.sh first"; exit 1; }

VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
DMG="$ROOT/build/DshDesktop-${VERSION}.dmg"

# Stage: a clean dir with the .app + Applications symlink.
STAGING="$(mktemp -d -t dsh-dmg)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> creating $DMG (UDZO read-only, with Applications link)"
hdiutil create \
  -volname "DshDesktop $VERSION" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG"

echo "==> ad-hoc signing DMG"
codesign --force --sign - "$DMG"

echo "==> verifying DMG"
codesign --verify --verbose=2 "$DMG" || true

echo "==> done"
ls -lh "$DMG"