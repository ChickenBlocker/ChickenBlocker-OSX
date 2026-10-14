#!/bin/bash
# ChickenBlocker-OSX verifier — Firefox policy + LeechBlock rule check & repair.
#
# Modes:
#   daemon  check and repair forever (used by the LaunchDaemon)
#   repair  one check-and-repair pass
#   check   audit only: PASS/FAIL/SKIP report, exit 1 on any FAIL
#
# Canonical ("expected") files live under BASE/expected and are installed by
# install.sh (Firefox policies) and sync-to-mac.sh (LeechBlock + keyword
# rules, pushed from the Linux ChickenBlocker machine). Live targets:
#   <Firefox.app>/Contents/Resources/distribution/policies.json
#   /Library/Application Support/Mozilla/ManagedStorage/leechblockng@proginosko.com.json
#   /Library/Application Support/Mozilla/ManagedStorage/page-keyword-filter-7f3a@local.addons.json
#   BASE/extensions/page_keyword_filter.xpi
#   <Firefox profile>/chrome/userChrome.css and userContent.css
#
# Extension enforcement (ports the Linux ChickenBlocker daemon): every Firefox
# profile's extensions.json is checked for a disabled/missing LeechBlock or
# Page Keyword Filter entry. On drift: Firefox is quit, the entry is
# re-enabled in extensions.json (active=true, userDisabled=false), the
# addonStartup cache is dropped, and Firefox is relaunched — but only if it
# was running before (never started on its own).
#
# Config: BASE/verifier.conf — CHECK_INTERVAL (seconds, default 15),
#         RESTART_FIREFOX_ON_REPAIR (0/1, default 1: when a managed-storage
#         file had to be repaired while Firefox is running, quit and relaunch
#         Firefox so LeechBlock re-copies the managed configuration).
#         Extension enforcement is NOT governed by this flag (it is the core
#         enforcement, mirroring Linux).
#
# Security posture: root can stop this daemon and edit ordinary files. It is
# the verifier/friction layer of the local track, not a root-resistant
# boundary; native binary denial is a later phase.
set -u

BASE="/Library/Application Support/ChickenBlocker"
EXPECTED="$BASE/expected"
LOGFILE="$BASE/verifier.log"
CONF="$BASE/verifier.conf"
PLIST="/Library/LaunchDaemons/com.chickenblocker.verifier.plist"
CHECK_INTERVAL=15
RESTART_FIREFOX_ON_REPAIR=1
EXT_RESTART_MIN_INTERVAL=300
[ -r "$CONF" ] && . "$CONF"

LB_ID="leechblockng@proginosko.com"
PKF_ID="page-keyword-filter-7f3a@local.addons"
MS_DIR="/Library/Application Support/Mozilla/ManagedStorage"

MODE="${1:-daemon}"
case "$MODE" in
  daemon|repair|check) ;;
  *) echo "usage: $0 [daemon|repair|check]" >&2; exit 2 ;;
esac

PASS=0
FAIL=0
SKIP=0
REPAIRED=0
REPAIRED_MANAGED=0
REPAIRED_RESTART=0
EXT_DRIFT_PROFILES=""
CONSOLE_USER=""
CONSOLE_UID=""

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGFILE" 2>/dev/null || true
  if [ -f "$LOGFILE" ]; then
    z="$(stat -f %z "$LOGFILE" 2>/dev/null || echo 0)"
    if [ "$z" -gt 131072 ]; then
      tail -n 400 "$LOGFILE" > "$LOGFILE.cbtmp" 2>/dev/null && mv "$LOGFILE.cbtmp" "$LOGFILE"
    fi
  fi
}

ext_py() {
cat <<'PY'
import json, os, sys
mode, prof = sys.argv[1], sys.argv[2]
ids = sys.argv[3:]
path = os.path.join(prof, "extensions.json")
try:
    with open(path, "r") as f:
        data = json.load(f)
except Exception:
    print("UNREADABLE"); sys.exit(2)
addons = data.get("addons")
if not isinstance(addons, list):
    print("UNREADABLE"); sys.exit(2)

def find(aid):
    for a in addons:
        if isinstance(a, dict) and a.get("id") == aid:
            return a
    return None

if mode == "check":
    bad = []
    for aid in ids:
        e = find(aid)
        if e is None:
            bad.append(aid.split("@")[0] + ":missing")
        elif e.get("active") is not True:
            bad.append(aid.split("@")[0] + ":inactive")
    if bad:
        print(" ".join(bad)); sys.exit(1)
    print("OK"); sys.exit(0)

changed = []
for aid in ids:
    e = find(aid)
    if e is None:
        changed.append(aid.split("@")[0] + ":missing(install-on-restart)")
    elif e.get("active") is not True or e.get("userDisabled") is not False:
        e["active"] = True
        e["userDisabled"] = False
        changed.append(aid.split("@")[0] + ":re-enabled")
if changed:
    tmp = path + ".cbtmp"
    with open(tmp, "w") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
    os.rename(tmp, path)
    print(",".join(changed))
PY
}

ext_ids() {
  ids="$LB_ID"
  [ -f "$BASE/extensions/page_keyword_filter.xpi" ] && ids="$ids $PKF_ID"
  printf '%s' "$ids"
}

# check_extension_state: audit all profiles; daemon/repair mode records drift
# profiles in EXT_DRIFT_PROFILES (newline-separated). Requires Full Disk
# Access for /bin/bash (System Settings -> Privacy & Security): the launchd
# daemon context is TCC-blocked from Firefox's profile container even as
# root, and "responsible process" attribution covers asuser/sudo children,
# so only the FDA grant lets the daemon read browser data.
check_extension_state() {
  if [ "$(id -u)" != 0 ]; then
    SKIP=$((SKIP+1))
    [ "$MODE" = check ] && echo "  [SKIP] extension-state — needs root (sudo)"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    SKIP=$((SKIP+1))
    [ "$MODE" = check ] && echo "  [SKIP] extension-state — python3 not available on this Mac"
    return
  fi
  if [ ! -f "$EXPECTED/leechblockng-managed-storage.json" ]; then
    SKIP=$((SKIP+1))
    [ "$MODE" = check ] && echo "  [SKIP] extension-state — rules not synced yet"
    return
  fi
  ids="$(ext_ids)"
  found=0
  for prof in /Users/*/Library/Application\ Support/Firefox/Profiles/*/; do
    [ -f "$prof/extensions.json" ] || continue
    found=1
    name="$(basename "$prof")"
    out="$(ext_py | python3 - check "$prof" $ids 2>"$BASE/.ext-err")"
    rc=$?
    if [ "$rc" = 0 ]; then
      PASS=$((PASS+1))
      [ "$MODE" = check ] && echo "  [PASS] extension-state[$name] — extensions active"
    elif [ "$rc" = 1 ]; then
      if [ "$MODE" = check ]; then
        FAIL=$((FAIL+1))
        echo "  [FAIL] extension-state[$name] — $out"
      else
        EXT_DRIFT_PROFILES="${EXT_DRIFT_PROFILES}${prof}
"
        log "EXTENSION-DRIFT $name: $out"
      fi
    else
      SKIP=$((SKIP+1))
      if [ "$MODE" = check ]; then
        echo "  [SKIP] extension-state[$name] — extensions.json unreadable ($(head -1 "$BASE/.ext-err" 2>/dev/null))"
      else
        log "EXTENSION-CHECK-ERROR $name rc=$rc: $(head -1 "$BASE/.ext-err" 2>/dev/null)"
      fi
    fi
  done
  if [ "$found" = 0 ]; then
    SKIP=$((SKIP+1))
    if [ "$MODE" = check ]; then
      echo "  [SKIP] extension-state — no Firefox profiles readable (grant Full Disk Access to the verifier interpreter (BASE/bin/cb-bash))"
    else
      log "EXTENSION-CHECK-ERROR no profile readable as root — grant Full Disk Access to the verifier interpreter (BASE/bin/cb-bash)"
    fi
  fi
}

# repair_profile <dir>: re-enable drifted extensions in one profile's
# extensions.json (Firefox must already be quit), drop the addonStartup
# cache. Runs as root (needs the same FDA grant); restores owner and mode.
repair_profile() {
  prof="$1"
  ids="$(ext_ids)"
  ext="$prof/extensions.json"
  [ -f "$ext" ] || return
  own="$(stat -f '%u:%g' "$ext" 2>/dev/null || true)"
  mod="$(stat -f '%Lp' "$ext" 2>/dev/null || echo 644)"
  out="$(ext_py | python3 - repair "$prof" $ids 2>/dev/null)"
  if [ -n "$out" ]; then
    [ -n "$own" ] && chown "$own" "$ext" 2>/dev/null
    chmod "$mod" "$ext" 2>/dev/null
    rm -f "$prof/addonStartup.json.lz4" "$prof/addonStartup.json" 2>/dev/null
    log "REPAIRED extensions.json in $prof: $out (startup cache dropped)"
  fi
}

resolve_console_user() {
  CONSOLE_USER=""
  CONSOLE_UID="$(stat -f %u /dev/console 2>/dev/null || true)"
  if [ -n "$CONSOLE_UID" ] && [ "$CONSOLE_UID" != 0 ]; then
    CONSOLE_USER="$(id -nu "$CONSOLE_UID" 2>/dev/null || true)"
  fi
}

firefox_running() { pgrep -x firefox >/dev/null 2>&1; }

quit_firefox() {
  resolve_console_user
  if [ -n "$CONSOLE_USER" ]; then
    launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" \
      osascript -e 'tell application "Firefox" to quit' >/dev/null 2>&1 || true
  fi
  i=0
  while [ "$i" -lt 10 ] && firefox_running; do
    sleep 1
    i=$((i+1))
  done
  pkill -x firefox 2>/dev/null || true
  sleep 1
}

relaunch_firefox() {
  resolve_console_user
  if [ -n "$CONSOLE_USER" ]; then
    launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" \
      open -a Firefox >/dev/null 2>&1 || true
    log "Firefox relaunched"
  else
    log "Firefox relaunch skipped (no GUI console user)"
  fi
}

# do_check <label> <expected-src> <live-dst> <managed-flag> [owner] [restart-flag]
# Sets global counters; check mode reports, daemon/repair mode repairs.
# owner defaults to root:wheel; the Firefox policies file is owned like the
# app bundle itself so Firefox's updater does not fall back to elevated
# (admin password) updates.
do_check() {
  label="$1"
  src="$2"
  dst="$3"
  managed="$4"
  owner="${5:-root:wheel}"
  restart="${6:-0}"

  if [ ! -f "$src" ]; then
    SKIP=$((SKIP+1))
    [ "$MODE" = check ] && echo "  [SKIP] $label — expected file not present: $src"
    return
  fi

  problem=""
  if [ ! -f "$dst" ]; then
    problem="missing"
  elif ! cmp -s "$src" "$dst"; then
    problem="content drift"
  elif [ "$(stat -f '%Su:%Sg' "$dst" 2>/dev/null)" != "$owner" ] ||
       [ "$(stat -f '%Lp' "$dst" 2>/dev/null)" != "644" ]; then
    problem="owner/mode"
  fi

  if [ -z "$problem" ]; then
    PASS=$((PASS+1))
    [ "$MODE" = check ] && echo "  [PASS] $label — $dst"
    return
  fi

  if [ "$MODE" = check ]; then
    FAIL=$((FAIL+1))
    echo "  [FAIL] $label — $problem: $dst"
    return
  fi

  mkdir -p "$(dirname "$dst")"
  if cp "$src" "$dst.cb-new" && chmod 0644 "$dst.cb-new" &&
     chown "$owner" "$dst.cb-new" && mv "$dst.cb-new" "$dst"; then
    REPAIRED=$((REPAIRED+1))
    [ "$managed" = 1 ] && REPAIRED_MANAGED=1
    [ "$restart" = 1 ] && REPAIRED_RESTART=1
    log "REPAIRED $label ($problem): $dst"
  else
    rm -f "$dst.cb-new"
    FAIL=$((FAIL+1))
    log "REPAIR-FAILED $label ($problem): $dst"
  fi
}

check_profile_stylesheets() {
  if [ ! -f "$EXPECTED/userChrome.css" ] || [ ! -f "$EXPECTED/userContent.css" ]; then
    SKIP=$((SKIP+1))
    [ "$MODE" = check ] && echo "  [SKIP] profile-stylesheets — run sync-to-mac.sh"
    return
  fi
  found=0
  for prof in /Users/*/Library/Application\ Support/Firefox/Profiles/*/; do
    [ -d "$prof" ] || continue
    found=1
    owner="$(stat -f '%Su:%Sg' "$prof" 2>/dev/null || echo root:wheel)"
    if [ "$MODE" != check ] && [ ! -d "$prof/chrome" ]; then
      mkdir -p "$prof/chrome"
      chown "$owner" "$prof/chrome" 2>/dev/null || true
    fi
    name="$(basename "$prof")"
    do_check "userChrome[$name]" "$EXPECTED/userChrome.css" \
      "$prof/chrome/userChrome.css" 0 "$owner" 1
    do_check "userContent[$name]" "$EXPECTED/userContent.css" \
      "$prof/chrome/userContent.css" 0 "$owner" 1
  done
  if [ "$found" = 0 ]; then
    SKIP=$((SKIP+1))
    [ "$MODE" = check ] && echo "  [SKIP] profile-stylesheets — no Firefox profiles found"
  fi
}

# check_firefox_policy_channel: Firefox policies arrive via the
# locally-installed user configuration profile (com.chickenblocker.firefox,
# managed org.mozilla.firefox preferences). A bare file dropped into
# /Library/Managed Preferences is NOT honored by Firefox, and macOS 27 has
# no CLI to (re)install profiles — so this is check-only. Verify both profile
# presence and materialized sentinel values; checking only the identifier can
# falsely accept an obsolete system-scoped or incomplete profile.
check_firefox_policy_channel() {
  if [ "$(id -u)" != 0 ]; then
    SKIP=$((SKIP+1))
    [ "$MODE" = check ] && echo "  [SKIP] firefox-profile — needs root (sudo)"
    return
  fi
  resolve_console_user
  problem=""
  if [ -z "$CONSOLE_USER" ]; then
    problem="no GUI console user"
  elif ! profiles show -type configuration -user "$CONSOLE_USER" 2>/dev/null | grep -q "com.chickenblocker.firefox"; then
    problem="not installed for $CONSOLE_USER"
  else
    prefs="/Library/Managed Preferences/$CONSOLE_USER/org.mozilla.firefox.plist"
    if [ ! -f "$prefs" ]; then
      problem="managed preferences not materialized for $CONSOLE_USER"
    elif [ "$(plutil -extract EnterprisePoliciesEnabled raw -o - "$prefs" 2>/dev/null || true)" != true ]; then
      problem="EnterprisePoliciesEnabled is not true (reinstall the current profile)"
    elif [ "$(plutil -extract DisablePrivateBrowsing raw -o - "$prefs" 2>/dev/null || true)" != true ]; then
      problem="DisablePrivateBrowsing is not true (reinstall the current profile)"
    fi
  fi
  if [ -z "$problem" ]; then
    PASS=$((PASS+1))
    [ "$MODE" = check ] && echo "  [PASS] firefox-profile — installed and active for $CONSOLE_USER"
    return
  fi
  if [ "$MODE" = check ]; then
    FAIL=$((FAIL+1))
    echo "  [FAIL] firefox-profile — $problem (System Settings: install $EXPECTED/org.mozilla.firefox.mobileconfig)"
    return
  fi
  now="$(date +%s)"
  last="$(cat "$BASE/.profile-warn-last" 2>/dev/null || echo 0)"
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now - last)) -ge 3600 ]; then
    echo "$now" > "$BASE/.profile-warn-last" 2>/dev/null || true
    log "WARN firefox-profile inactive: $problem — install $EXPECTED/org.mozilla.firefox.mobileconfig via System Settings"
  fi
}

run_pass() {
  PASS=0; FAIL=0; SKIP=0; REPAIRED=0; REPAIRED_MANAGED=0; REPAIRED_RESTART=0; EXT_DRIFT_PROFILES=""

  check_firefox_policy_channel

  do_check "leechblock-managed-storage" \
    "$EXPECTED/leechblockng-managed-storage.json" \
    "$MS_DIR/$LB_ID.json" 1

  do_check "pkf-managed-storage" \
    "$EXPECTED/pkf-managed-storage.json" \
    "$MS_DIR/$PKF_ID.json" 1

  do_check "pkf-extension" \
    "$EXPECTED/extensions/page_keyword_filter.xpi" \
    "/usr/local/lib/ChickenBlocker/page_keyword_filter.xpi" 0

  do_check "pkf-extension-legacy" \
    "$EXPECTED/extensions/page_keyword_filter.xpi" \
    "$BASE/extensions/page_keyword_filter.xpi" 0

  check_extension_state
  check_profile_stylesheets

  if [ "$MODE" = check ]; then
    if [ -f "$PLIST" ]; then
      PASS=$((PASS+1)); echo "  [PASS] LaunchDaemon plist — $PLIST"
    else
      FAIL=$((FAIL+1)); echo "  [FAIL] LaunchDaemon plist — $PLIST missing"
    fi
    if [ "$(id -u)" = 0 ]; then
      if launchctl print system/com.chickenblocker.verifier >/dev/null 2>&1; then
        PASS=$((PASS+1)); echo "  [PASS] LaunchDaemon loaded"
      else
        FAIL=$((FAIL+1)); echo "  [FAIL] LaunchDaemon not loaded"
      fi
    else
      SKIP=$((SKIP+1)); echo "  [SKIP] LaunchDaemon state — needs root (sudo)"
    fi
  fi
}

# recovery: act on drift found by run_pass (daemon/repair modes only).
# Extension drift is always enforced; managed-storage restart honours
# RESTART_FIREFOX_ON_REPAIR. Firefox is only relaunched if it was running
# when the pass started.
recovery() {
  was_running=0
  firefox_running && was_running=1
  killed=0

  # Flush preference caches so a repaired managed-prefs file is re-read.
  if [ "$REPAIRED" -gt 0 ]; then
    killall cfprefsd 2>/dev/null || true
  fi

  if [ -n "$EXT_DRIFT_PROFILES" ]; then
    if [ "$was_running" != 1 ]; then
      while IFS= read -r prof; do
        [ -n "$prof" ] || continue
        repair_profile "$prof"
      done <<< "$EXT_DRIFT_PROFILES"
    else
      now="$(date +%s)"
      last="$(cat "$BASE/.ext-restart-last" 2>/dev/null || echo 0)"
      case "$now" in ''|*[!0-9]*) now=0 ;; esac
      case "$last" in ''|*[!0-9]*) last=0 ;; esac
      if [ $((now - last)) -ge "$EXT_RESTART_MIN_INTERVAL" ]; then
        echo "$now" > "$BASE/.ext-restart-last" 2>/dev/null || true
        log "extension drift — quitting Firefox for extensions.json repair"
        quit_firefox
        killed=1
        while IFS= read -r prof; do
          [ -n "$prof" ] || continue
          repair_profile "$prof"
        done <<< "$EXT_DRIFT_PROFILES"
      else
        log "extension drift persists — restart suppressed (rate limit ${EXT_RESTART_MIN_INTERVAL}s); install may be failing"
      fi
    fi
  fi

  want_managed_restart=0
  { [ "$REPAIRED_MANAGED" = 1 ] || [ "$REPAIRED_RESTART" = 1 ]; } &&
    [ "$RESTART_FIREFOX_ON_REPAIR" = 1 ] && want_managed_restart=1

  if [ "$want_managed_restart" = 1 ] || [ "$killed" = 1 ]; then
    if [ "$was_running" = 1 ]; then
      if firefox_running; then
        log "Firefox state repaired while running — controlled restart"
        quit_firefox
        killed=1
      fi
      if ! firefox_running; then
        relaunch_firefox
      fi
    else
      log "drift repaired while Firefox not running — not launching it"
    fi
  fi
}

case "$MODE" in
  daemon)
    sleep_pid=""
    trap 'log "verifier stopped"; [ -n "$sleep_pid" ] && kill "$sleep_pid" 2>/dev/null; exit 0' INT TERM
    log "verifier started (pid $$, interval ${CHECK_INTERVAL}s)"
    log "diag: python3=$(command -v python3 2>/dev/null || echo MISSING) console=$(stat -f %Su /dev/console 2>/dev/null || echo ?) ids=[$(ext_ids 2>/dev/null)]"
    while :; do
      run_pass
      recovery
      sleep "$CHECK_INTERVAL" &
      sleep_pid=$!
      wait $!
      sleep_pid=""
    done
    ;;
  repair)
    run_pass
    recovery
    echo "repaired=$REPAIRED failed=$FAIL skipped=$SKIP passed=$PASS"
    [ "$FAIL" = 0 ]
    ;;
  check)
    echo "=== ChickenBlocker-OSX verify ==="
    run_pass
    echo
    echo "=== RESULT: $PASS passed, $FAIL failed, $SKIP skipped ==="
    [ "$FAIL" = 0 ]
    ;;
esac
