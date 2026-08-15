#!/usr/bin/env bash
# Ad-hoc sign the .app for personal use. Not notarized; Gatekeeper will require
# right-click → Open the first time. Acceptable for personal use per spec §1.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/DshDesktop.app"

test -d "$APP" || { echo "no $APP — run ./scripts/bundle.sh first"; exit 1; }

echo "==> codesign --force --deep --sign - $APP"
codesign --force --deep --sign - "$APP"

echo "==> verifying"
codesign --verify --verbose=2 "$APP" || true
echo "==> done"
