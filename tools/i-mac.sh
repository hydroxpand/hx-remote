#!/bin/bash
# HX Remote installer for macOS (no admin rights needed). In Terminal:
#   curl -fsSL https://raw.githubusercontent.com/hydroxpand/hx-remote/hx/tools/i-mac.sh | bash
# Installs the newest HX Remote build to ~/Applications/RustDesk.app (shown as "HX Remote"),
# the menu bar icon (LaunchAgent com.hydroxpand.hxremote.tray) and the hourly auto-update
# (LaunchAgent com.hydroxpand.hxremote.update, script tools/hxupdate-mac.sh).
# Remove: launchctl bootout gui/$(id -u)/com.hydroxpand.hxremote.update (and .tray), delete the two
# plists in ~/Library/LaunchAgents, ~/Library/Application Support/HX-Remote-Updater and the app.
set -u
REF="${HX_REF:-hx}"
DIR="$HOME/Library/Application Support/HX-Remote-Updater"
AG="$HOME/Library/LaunchAgents"
APP="$HOME/Applications/RustDesk.app"
UID_GUI="gui/$(id -u)"
mkdir -p "$DIR" "$AG" "$HOME/Applications"

echo "== HX Remote setup on $(scutil --get ComputerName 2>/dev/null || hostname) =="
curl -fsSL "https://raw.githubusercontent.com/hydroxpand/hx-remote/$REF/tools/hxupdate-mac.sh" -o "$DIR/hxupdate-mac.sh" \
  || { echo "download of the updater failed"; exit 1; }
chmod 755 "$DIR/hxupdate-mac.sh"

cat > "$AG/com.hydroxpand.hxremote.update.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.hydroxpand.hxremote.update</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$DIR/hxupdate-mac.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF

cat > "$AG/com.hydroxpand.hxremote.tray.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.hydroxpand.hxremote.tray</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/RustDesk</string>
        <string>--tray</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

# install or update the app now (ignores the idle check)
echo "installing the newest build ..."
HX_FORCE=1 /bin/bash "$DIR/hxupdate-mac.sh"
[ -d "$APP" ] || { echo "INSTALL FAILED (see $DIR/update.log)"; exit 1; }

for L in update tray; do
  launchctl bootout "$UID_GUI/com.hydroxpand.hxremote.$L" 2>/dev/null
  launchctl bootstrap "$UID_GUI" "$AG/com.hydroxpand.hxremote.$L.plist"
done
pgrep -f "RustDesk.app/Contents/MacOS/RustDesk$" >/dev/null || open "$APP"

echo
echo "   HX Remote installed: $(cat "$DIR/build.txt" 2>/dev/null)"
echo "   auto-update: every hour when the Mac is idle (log: $DIR/update.log)"
echo "   To be controlled from other PCs, allow HX Remote in System Settings >"
echo "   Privacy & Security > Screen Recording and Accessibility."
