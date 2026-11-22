#!/bin/bash
# HX Remote auto-update for macOS (per user, no admin rights needed).
# Installed by tools/i-mac.sh to ~/Library/Application Support/HX-Remote-Updater/ and run every hour
# by ~/Library/LaunchAgents/com.hydroxpand.hxremote.update.plist.
# Picks the newest complete hx-* release of hydroxpand/hx-remote (one with SHA256SUMS). On Apple
# silicon it prefers the aarch64 dmg; when a release has no aarch64 build (GitHub arm64 runners
# were short at times) it takes the x86_64 dmg, which runs under Rosetta, and switches to aarch64
# once that build of the same release appears. It only replaces the app when nobody has used this
# Mac for 30 minutes (so a remote session in use is not cut), checks SHA-256 and the code signature,
# keeps the previous app as RustDesk.app.prev, and relaunches the app if it was running.
# The app lives in ~/Applications/HX Remote.app (the Dock shows the file name); installs made
# before 261111 used RustDesk.app and are renamed once, when nobody is using the Mac.
# After an update it also refreshes this script from the hx branch.
#   HX_FORCE=1  ignore the idle check (used by the installer)
#   HX_DRY=1    pick, download and verify, but do not replace anything
set -u
REPO="hydroxpand/hx-remote"
APP="$HOME/Applications/HX Remote.app"
OLD="$HOME/Applications/RustDesk.app"   # name used up to 261111
PAT='Applications/(HX Remote|RustDesk)\.app/Contents/MacOS/RustDesk'
TRAY="$HOME/Library/LaunchAgents/com.hydroxpand.hxremote.tray.plist"
SRV="$HOME/Library/LaunchAgents/com.hydroxpand.hxremote.server.plist"   # "--server", since 261113
DIR="$HOME/Library/Application Support/HX-Remote-Updater"
MARK="$DIR/build.txt"          # "<tag> <arch>" of the installed build
# Copy of the app that runs the menu bar icon and "--server" under its own bundle id. With all three
# processes under com.carriez.rustdesk, macOS automation (Claude computer use app_* tools, AppleScript
# by bundle id) picked the tray process and never saw the app's windows (261122).
SVC="$DIR/HX Remote Service.app"
SVC_ID="com.hydroxpand.hxremote.service"
LOG="$DIR/update.log"
mkdir -p "$DIR"
# "update now" button in the app drops this flag: skip the idle wait
if [ -f "$DIR/force" ]; then rm -f "$DIR/force"; HX_FORCE=1; fi
log() { echo "$(date '+%Y-%m-%dT%H:%M:%S')  $*" >> "$LOG"; [ -n "${HX_VERBOSE:-}${HX_DRY:-}${HX_FORCE:-}" ] && echo "$*"; }
[ -f "$LOG" ] && [ "$(stat -f%z "$LOG")" -gt 200000 ] && rm -f "$LOG"

WANT=x86_64
[ "$(/usr/bin/uname -m)" = "arm64" ] && WANT=aarch64
ROSETTA=0
/usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null && ROSETTA=1

# helpers shared by the rename and the update
idle_secs() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'; }
stop_app() {
  launchctl bootout "gui/$(id -u)/com.hydroxpand.hxremote.tray" 2>/dev/null
  # the server agent has KeepAlive: unload it, or it restarts the app while it is being replaced
  launchctl bootout "gui/$(id -u)/com.hydroxpand.hxremote.server" 2>/dev/null
  osascript -e 'tell application id "com.carriez.rustdesk" to quit' >/dev/null 2>&1
  for _ in $(seq 1 20); do pgrep -f "$PAT" >/dev/null || break; sleep 0.5; done
  pkill -f "$PAT" 2>/dev/null; sleep 1
}
make_service() {
  # fresh copy of the app with its own bundle id, menu bar only, no rustdesk:// links, ad-hoc signed
  rm -rf "$SVC"
  ditto "$APP" "$SVC" || { log "service copy failed"; rm -rf "$SVC"; return 1; }
  local P="$SVC/Contents/Info.plist" B=/usr/libexec/PlistBuddy
  $B -c "Set :CFBundleIdentifier $SVC_ID" "$P"
  $B -c "Set :CFBundleName HX Remote Service" -c "Set :CFBundleDisplayName HX Remote Service" "$P"
  $B -c "Delete :CFBundleURLTypes" "$P" 2>/dev/null
  $B -c "Delete :LSUIElement" -c "Add :LSUIElement bool true" "$P"
  codesign --force --deep -s - "$SVC" 2>/dev/null || { log "service signing failed"; rm -rf "$SVC"; return 1; }
  cat "$MARK" > "$SVC/Contents/hx-build.txt" 2>/dev/null
  log "service copy made ($(cat "$MARK" 2>/dev/null))"
}
start_tray() {
  # the menu bar and server agents run the service copy (made from the current app when missing or stale)
  if [ -d "$APP" ] && { [ ! -d "$SVC" ] || ! cmp -s "$MARK" "$SVC/Contents/hx-build.txt"; }; then make_service; fi
  local EXE="$APP/Contents/MacOS/RustDesk"
  [ -d "$SVC" ] && EXE="$SVC/Contents/MacOS/RustDesk"
  for F in "$TRAY" "$SRV"; do
    [ -f "$F" ] || continue
    /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $EXE" "$F"
    launchctl bootstrap "gui/$(id -u)" "$F" 2>/dev/null
  done
}
# move the tray and server agents to the service copy (installs made before 261122), or remake a
# stale copy, without waiting for the next release; the running app window is left alone
fix_service() {
  [ -d "$APP" ] && [ -z "${HX_DRY:-}" ] || return 0
  local need=0
  [ -d "$SVC" ] && cmp -s "$MARK" "$SVC/Contents/hx-build.txt" || need=1
  for F in "$TRAY" "$SRV"; do
    [ -f "$F" ] && ! grep -q "HX Remote Service.app" "$F" && need=1
  done
  [ "$need" = 0 ] && return 0
  launchctl bootout "gui/$(id -u)/com.hydroxpand.hxremote.tray" 2>/dev/null
  launchctl bootout "gui/$(id -u)/com.hydroxpand.hxremote.server" 2>/dev/null
  pkill -f "MacOS/RustDesk --(tray|server)\$" 2>/dev/null; sleep 2
  start_tray
}

# one-time rename RustDesk.app -> HX Remote.app (not while someone is using the Mac)
if [ -d "$OLD" ] && [ ! -d "$APP" ] && [ -z "${HX_DRY:-}" ]; then
  WAS=0; pgrep -f "$PAT\$" >/dev/null && WAS=1
  if [ "$WAS" = 0 ] || [ -n "${HX_FORCE:-}" ] || [ "$(idle_secs)" -ge 1800 ]; then
    stop_app
    mv "$OLD" "$APP" && log "renamed RustDesk.app -> HX Remote.app"
    [ "$WAS" = 1 ] && open "$APP"
    start_tray
  fi
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hxupd.XXXXXX") || exit 0
trap 'hdiutil detach -quiet "$TMP/mnt" 2>/dev/null; rm -rf "$TMP"' EXIT

curl -fsSL -H 'User-Agent: hx-remote-updater' \
  "https://api.github.com/repos/$REPO/releases?per_page=20" -o "$TMP/rel.json" || { log "GitHub API failed"; exit 0; }

# -> "<tag> <arch> <dmg url> <dmg name> <sums url>" of the best release, or nothing
PICK=$(/usr/bin/python3 - "$TMP/rel.json" "$WANT" "$ROSETTA" <<'PY'
import json, re, sys
rels = json.load(open(sys.argv[1]))
want, rosetta = sys.argv[2], sys.argv[3] == "1"
best = None
for r in rels:
    m = re.fullmatch(r"hx-(\d+)\.(\d+)\.(\d+)-(\d+)", r.get("tag_name", ""))
    if not m or r.get("draft"):
        continue
    assets = {a["name"]: a["browser_download_url"] for a in r.get("assets", [])}
    if "SHA256SUMS" not in assets:
        continue
    arches = [want] + (["x86_64"] if want == "aarch64" and rosetta else [])
    for arch in arches:
        name = next((n for n in assets if n.endswith(f"-{arch}.dmg")), None)
        if name:
            key = tuple(int(x) for x in m.groups())
            if best is None or key > best[0]:
                best = (key, r["tag_name"], arch, assets[name], name, assets["SHA256SUMS"])
            break
if best:
    print(*best[1:])
PY
)
[ -z "$PICK" ] && { log "no usable release"; exit 0; }
read -r TAG ARCH URL NAME SUMS <<< "$PICK"

ver() { echo "$1" | sed -E 's/^hx-([0-9]+)\.([0-9]+)\.([0-9]+)-([0-9]+)$/\1 \2 \3 \4/' | awk '{printf "%05d%05d%05d%05d", $1, $2, $3, $4}'; }
CUR_TAG=""; CUR_ARCH=""
[ -f "$MARK" ] && read -r CUR_TAG CUR_ARCH < "$MARK"
NEED=0
if [ ! -d "$APP" ] || [ -z "$CUR_TAG" ]; then NEED=1
elif [ "$(ver "$TAG")" \> "$(ver "$CUR_TAG")" ]; then NEED=1
elif [ "$TAG" = "$CUR_TAG" ] && [ "$CUR_ARCH" = "x86_64" ] && [ "$ARCH" = "aarch64" ]; then NEED=1
fi
[ "$NEED" = 0 ] && { fix_service; [ -n "${HX_DRY:-}${HX_VERBOSE:-}" ] && echo "up to date: $CUR_TAG $CUR_ARCH"; exit 0; }

RUNNING=0
pgrep -f "$PAT\$" >/dev/null && RUNNING=1
IDLE=$(idle_secs)
if [ "$RUNNING" = 1 ] && [ -z "${HX_FORCE:-}" ] && [ -z "${HX_DRY:-}" ] && [ "${IDLE:-0}" -lt 1800 ]; then
  exit 0   # someone is using this Mac; try again next hour (no log line, keeps the log small)
fi

log "update ${CUR_TAG:-none} ${CUR_ARCH} -> $TAG $ARCH"
curl -fsSL "$URL" -o "$TMP/$NAME" && curl -fsSL "$SUMS" -o "$TMP/SHA256SUMS" || { log "download failed"; exit 0; }
WANT_SUM=$(awk -v n="$NAME" '$2==n || $2=="*"n {print $1}' "$TMP/SHA256SUMS" | head -1)
GOT_SUM=$(shasum -a 256 "$TMP/$NAME" | awk '{print $1}')
[ -n "$WANT_SUM" ] && [ "$WANT_SUM" = "$GOT_SUM" ] || { log "checksum mismatch for $NAME, not installing"; exit 0; }
mkdir -p "$TMP/mnt"
hdiutil attach -nobrowse -readonly -mountpoint "$TMP/mnt" "$TMP/$NAME" >/dev/null || { log "cannot open dmg"; exit 0; }
ditto "$TMP/mnt/RustDesk.app" "$TMP/RustDesk.app"
hdiutil detach -quiet "$TMP/mnt"
codesign -v --deep "$TMP/RustDesk.app" 2>/dev/null || { log "signature check failed, not installing"; exit 0; }
if [ -n "${HX_DRY:-}" ]; then log "dry run: $TAG $ARCH downloaded and verified, nothing replaced"; exit 0; fi

# replace the app
stop_app
mkdir -p "$HOME/Applications"
rm -rf "$DIR/RustDesk.app.prev"
[ -d "$APP" ] && mv "$APP" "$DIR/RustDesk.app.prev"
[ -d "$OLD" ] && rm -rf "$OLD"   # old name left over: the new copy replaces it
ditto "$TMP/RustDesk.app" "$APP" || { log "copy failed, restoring previous app"; [ -d "$DIR/RustDesk.app.prev" ] && mv "$DIR/RustDesk.app.prev" "$APP"; exit 1; }
echo "$TAG $ARCH" > "$MARK"
[ "$RUNNING" = 1 ] && open "$APP"
start_tray
log "done $TAG $ARCH"
# refresh this script from the hx branch (a new file, so the running copy is not disturbed)
if curl -fsSL "https://raw.githubusercontent.com/$REPO/hx/tools/hxupdate-mac.sh" -o "$DIR/.hxupdate-mac.new" \
   && /bin/bash -n "$DIR/.hxupdate-mac.new"; then
  chmod 755 "$DIR/.hxupdate-mac.new" && mv -f "$DIR/.hxupdate-mac.new" "$DIR/hxupdate-mac.sh"
else
  rm -f "$DIR/.hxupdate-mac.new"
fi
