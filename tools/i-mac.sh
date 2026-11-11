#!/bin/bash
# HX Remote installer for macOS (no admin rights needed). In Terminal:
#   curl -fsSL https://raw.githubusercontent.com/hydroxpand/hx-remote/hx/tools/i-mac.sh | bash
# Installs the newest HX Remote build to ~/Applications/HX Remote.app (RustDesk.app before 261111),
# the menu bar icon (LaunchAgent com.hydroxpand.hxremote.tray) and the hourly auto-update
# (LaunchAgent com.hydroxpand.hxremote.update, script tools/hxupdate-mac.sh).
# Laptops used outside the office also need Cloudflare WARP to reach the company HX Remote server:
#   curl -fsSL https://raw.githubusercontent.com/hydroxpand/hx-remote/hx/tools/i-mac.sh | bash -s -- --warp
# (asks for the Mac password once; then sign in to WARP with the company e-mail once)
# Remove: launchctl bootout gui/$(id -u)/com.hydroxpand.hxremote.update (and .tray), delete the two
# plists in ~/Library/LaunchAgents, ~/Library/Application Support/HX-Remote-Updater and the app.
set -u
REF="${HX_REF:-hx}"
# Cloudflare Zero Trust team name (set when the company Zero Trust org is ready)
WARP_ORG="purple-pond-45f0"
WARP=0
for arg in "$@"; do [ "$arg" = "--warp" ] && WARP=1; done
DIR="$HOME/Library/Application Support/HX-Remote-Updater"
AG="$HOME/Library/LaunchAgents"
APP="$HOME/Applications/HX Remote.app"
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
  # bootout finishes in the background; bootstrap right after it can fail with "Input/output error"
  for _ in 1 2 3 4 5; do
    sleep 1
    launchctl bootstrap "$UID_GUI" "$AG/com.hydroxpand.hxremote.$L.plist" 2>/dev/null && break
  done
done
pgrep -f 'Applications/(HX Remote|RustDesk)\.app/Contents/MacOS/RustDesk$' >/dev/null || open "$APP"

# Cloudflare WARP (optional): official package, signature checked, organization preset
if [ "$WARP" = 1 ]; then
  if [ -z "$WARP_ORG" ]; then
    echo "WARP: company setup not ready yet, skipped (run this installer again later)"
  elif [ -d "/Applications/Cloudflare WARP.app" ]; then
    echo "WARP: already installed"
  else
    echo "WARP: downloading Cloudflare WARP ..."
    WT=$(mktemp -d "${TMPDIR:-/tmp}/hxwarp.XXXXXX")
    if curl -fsSL "https://downloads.cloudflareclient.com/v1/download/macos/ga" -o "$WT/Cloudflare_WARP.pkg" \
       && pkgutil --check-signature "$WT/Cloudflare_WARP.pkg" | grep -q "Cloudflare" \
       && pkgutil --check-signature "$WT/Cloudflare_WARP.pkg" | grep -q "signed by a developer certificate issued by Apple"; then
      echo "WARP: installing (enter this Mac's password if asked) ..."
      sudo /bin/sh -c "mkdir -p '/Library/Application Support/Cloudflare' && cat > '/Library/Application Support/Cloudflare/mdm.xml' <<X
<dict>
  <key>organization</key>
  <string>$WARP_ORG</string>
</dict>
X
installer -pkg '$WT/Cloudflare_WARP.pkg' -target /" \
        && echo "WARP: installed. Open Cloudflare WARP and sign in with your company e-mail once." \
        || echo "WARP: install failed"
    else
      echo "WARP: download or signature check failed, not installing"
    fi
    rm -rf "$WT"
  fi
fi

echo
echo "   HX Remote installed: $(cat "$DIR/build.txt" 2>/dev/null)"
echo "   auto-update: every hour when the Mac is idle (log: $DIR/update.log)"
echo "   To be controlled from other PCs, allow HX Remote in System Settings >"
echo "   Privacy & Security > Screen Recording and Accessibility."
