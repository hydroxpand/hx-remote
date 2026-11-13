#!/bin/bash
# HX Remote installer for macOS (no admin rights needed). In Terminal:
#   curl -fsSL https://raw.githubusercontent.com/hydroxpand/hx-remote/hx/tools/i-mac.sh | bash
# Installs the newest HX Remote build to ~/Applications/HX Remote.app (RustDesk.app before 261111),
# the background service that registers this Mac's ID (LaunchAgent com.hydroxpand.hxremote.server,
# "RustDesk --server"; without it the app never shows "Ready"), the menu bar icon
# (LaunchAgent com.hydroxpand.hxremote.tray) and the hourly auto-update
# (LaunchAgent com.hydroxpand.hxremote.update, script tools/hxupdate-mac.sh).
# It points the app at the company HX Remote server (ID and relay); the public RustDesk servers
# now ask the connecting side to sign in. Running it again on an installed Mac switches that Mac
# to the company server too. It does not set an unattended-access password.
# Laptops used outside the office also need Cloudflare WARP to reach the company HX Remote server:
#   curl -fsSL https://raw.githubusercontent.com/hydroxpand/hx-remote/hx/tools/i-mac.sh | bash -s -- --warp
# (asks for the Mac password once; then sign in to WARP with the company e-mail once)
# Remove: launchctl bootout gui/$(id -u)/com.hydroxpand.hxremote.update (and .tray, .server), delete
# the three plists in ~/Library/LaunchAgents, ~/Library/Application Support/HX-Remote-Updater and the app.
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
# company HX Remote server (hbbs/hbbr); HX_KEY is the server's public key, not a secret
HX_SERVER="172.30.1.34"
HX_KEY="ABuiNiIojpQ534We4SQfM1sW4laAXW8fBEfR7U+IrEU="
CONF="$HOME/Library/Preferences/com.carriez.HX-Remote/HX-Remote2.toml"
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

cat > "$AG/com.hydroxpand.hxremote.server.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.hydroxpand.hxremote.server</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/RustDesk</string>
        <string>--server</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
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

# stop the app so it does not write its old settings back over the server settings below
PAT='Applications/(HX Remote|RustDesk)\.app/Contents/MacOS/RustDesk'
for L in update tray server; do launchctl bootout "$UID_GUI/com.hydroxpand.hxremote.$L" 2>/dev/null; done
osascript -e 'tell application id "com.carriez.rustdesk" to quit' >/dev/null 2>&1
for _ in $(seq 1 20); do pgrep -f "$PAT" >/dev/null || break; sleep 0.5; done
pkill -f "$PAT" 2>/dev/null; sleep 1

# company server in [options] of the app settings (other settings, ID and password are kept)
mkdir -p "$(dirname "$CONF")"
if /usr/bin/python3 - "$CONF" "$HX_SERVER" "$HX_KEY" <<'PY'
import os, sys
path, server, key = sys.argv[1:4]
want = {"custom-rendezvous-server": server, "relay-server": server, "key": key}
lines = open(path).read().splitlines() if os.path.exists(path) else []
out, section, done, seen = [], None, set(), False
def add_missing():
    for k, v in want.items():
        if k not in done:
            out.append(f"{k} = '{v}'"); done.add(k)
for line in lines:
    t = line.strip()
    if t.startswith("[") and t.endswith("]"):
        if section == "options":
            add_missing()
        section = t[1:-1].strip()
        seen = seen or section == "options"
    elif section == "options" and "=" in t:
        k = t.split("=", 1)[0].strip().strip("'\"")
        if k in want:
            if k not in done:
                out.append(f"{k} = '{want[k]}'"); done.add(k)
            continue
    out.append(line)
if section == "options":
    add_missing()
if not seen:
    if out and out[-1].strip():
        out.append("")
    out.append("[options]")
    add_missing()
tmp = path + ".hxnew"
open(tmp, "w").write("\n".join(out) + "\n")
os.replace(tmp, path)
PY
then echo "server: $HX_SERVER (company)"
else echo "WARNING: could not write the server settings to $CONF"
fi

for L in update tray server; do
  # bootout finishes in the background; bootstrap right after it can fail with "Input/output error"
  for _ in 1 2 3 4 5; do
    sleep 1
    launchctl bootstrap "$UID_GUI" "$AG/com.hydroxpand.hxremote.$L.plist" 2>/dev/null && break
  done
done
pgrep -f "$PAT\$" >/dev/null || open "$APP"

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
echo "   server: $HX_SERVER (\"Ready\" appears in the app within a minute)"
echo "   auto-update: every hour when the Mac is idle (log: $DIR/update.log)"
echo "   To be controlled from other PCs, allow HX Remote in System Settings >"
echo "   Privacy & Security > Screen Recording and Accessibility."
