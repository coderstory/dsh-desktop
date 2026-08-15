#!/usr/bin/env bash
# Build the executable with SwiftPM and wrap it in a .app bundle.
#
# Output: build/DshDesktop.app
# Run:    ./scripts/bundle.sh   # then open build/DshDesktop.app

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"
EXEC="$BIN_PATH/DshDesktop"
test -x "$EXEC" || { echo "expected executable at $EXEC"; exit 1; }

APP="$ROOT/build/DshDesktop.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "==> constructing $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$EXEC" "$MACOS/DshDesktop"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>ai.deepseek.dsh.desktop</string>
    <key>CFBundleName</key>
    <string>DshDesktop</string>
    <key>CFBundleDisplayName</key>
    <string>dsh</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleExecutable</key>
    <string>DshDesktop</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
PLIST

echo "==> wrote $APP"
echo "next: ./scripts/sign.sh"
