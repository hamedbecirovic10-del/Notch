#!/bin/bash
# Builds Notch.app (release, universal-ish for this Mac) into ./dist.
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/Notch.app"
echo "▸ Compiling release binary…"
swift build -c release

echo "▸ Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Notch "$APP/Contents/MacOS/Notch"
cp Info.plist "$APP/Contents/Info.plist"
# Bundle brand logos + any other resources.
if [ -d "Resources" ]; then
  cp Resources/*.png "$APP/Contents/Resources/" 2>/dev/null || true
  cp Resources/*.icns "$APP/Contents/Resources/" 2>/dev/null || true
fi

echo "▸ Ad-hoc code signing…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ Built $APP"
