#!/bin/bash
# Installs Notch to ~/Applications and registers it to launch at login and
# stay alive. To fully stop it: run ./uninstall.sh (or delete the app bundle
# and the LaunchAgent plist).
set -euo pipefail
cd "$(dirname "$0")"

APP_SRC="dist/Notch.app"
APP_DST="$HOME/Applications/Notch.app"
PLIST="$HOME/Library/LaunchAgents/com.hamed.notch.plist"
BIN="$APP_DST/Contents/MacOS/Notch"

[ -d "$APP_SRC" ] || { echo "Build first: ./build.sh"; exit 1; }

echo "▸ Installing to $APP_DST"
mkdir -p "$HOME/Applications"
# Stop any running/installed instance so we can replace it.
launchctl bootout "gui/$(id -u)/com.hamed.notch" 2>/dev/null || true
pkill -f "Notch.app/Contents/MacOS/Notch" 2>/dev/null || true
sleep 1
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

echo "▸ Writing LaunchAgent $PLIST"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.hamed.notch</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
</dict>
</plist>
PLIST_EOF

echo "▸ Loading agent (starts Notch now, and at every login)"
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "✓ Installed. Notch is running and starts automatically at every login."
echo "  Quit anytime by right-clicking the notch → Quit Notch (it comes back"
echo "  at next login). To remove it permanently: ./uninstall.sh"
