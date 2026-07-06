#!/bin/bash
# Completely removes Notch: stops it, unregisters the login item, deletes files.
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/com.hamed.notch.plist"
APP_DST="$HOME/Applications/Notch.app"

echo "▸ Stopping and unregistering…"
launchctl bootout "gui/$(id -u)/com.hamed.notch" 2>/dev/null || true
pkill -f "Notch.app/Contents/MacOS/Notch" 2>/dev/null || true

echo "▸ Removing files…"
rm -f "$PLIST"
rm -rf "$APP_DST"

echo "✓ Notch fully removed."
