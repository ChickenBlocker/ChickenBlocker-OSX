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
#
# Config: BASE/verifier.conf — CHECK_INTERVAL (seconds, default 15),
#         RESTART_FIREFOX_ON_REPAIR (0/1, default 1: when a managed-storage
#         file had to be repaired while Firefox is running, quit and relaunch
#         Firefox so LeechBlock re-copies the managed configuration).
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

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGFILE" 2>/dev/null || true
  if [ -f "$LOGFILE" ]; then
    z="$(stat -f %z "$LOGFILE" 2>/dev/null || echo 0)"
    if [ "$z" -gt 131072 ]; then
      tail -n 400 "$LOGFILE" > "$LOGFILE.cbtmp" 2>/dev/null && mv "$LOGFILE.cbtmp" "$LOGFILE"
    fi
  fi
}

# do_check <label> <expected-src> <live-dst> <managed-flag>
# Sets global counters; check mode reports, daemon/repair mode repairs.
do_check() {
  label="$1"
  src="$2"
  dst="$3"
  managed="$4"

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
  elif [ "$(stat -f '%Su:%Sg' "$dst" 2>/dev/null)" != "root:wheel" ] ||
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
     chown root:wheel "$dst.cb-new" && mv "$dst.cb-new" "$dst"; then
    REPAIRED=$((REPAIRED+1))
    [ "$managed" = 1 ] && REPAIRED_MANAGED=1
    log "REPAIRED $label ($problem): $dst"
  else
    rm -f "$dst.cb-new"
    FAIL=$((FAIL+1))
    log "REPAIR-FAILED $label ($problem): $dst"
  fi
}

run_pass() {
  PASS=0; FAIL=0; SKIP=0; REPAIRED=0; REPAIRED_MANAGED=0

  found_ff=0
  for app in /Applications/Firefox.app /Users/*/Applications/Firefox.app; do
    [ -d "$app" ] || continue
    found_ff=1
    do_check "firefox-policies" \
      "$EXPECTED/firefox-policies.json" \
      "$app/Contents/Resources/distribution/policies.json" 0
  done
  if [ "$found_ff" = 0 ]; then
    SKIP=$((SKIP+1))
    [ "$MODE" = check ] && echo "  [SKIP] firefox-policies — Firefox.app not found"
  fi

  do_check "leechblock-managed-storage" \
    "$EXPECTED/leechblockng-managed-storage.json" \
    "$MS_DIR/$LB_ID.json" 1

  do_check "pkf-managed-storage" \
    "$EXPECTED/pkf-managed-storage.json" \
    "$MS_DIR/$PKF_ID.json" 1

  do_check "pkf-extension" \
    "$EXPECTED/extensions/page_keyword_filter.xpi" \
    "$BASE/extensions/page_keyword_filter.xpi" 0

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

maybe_restart() {
  [ "$REPAIRED_MANAGED" = 1 ] || return
  [ "$RESTART_FIREFOX_ON_REPAIR" = 1 ] || return
  pgrep -x firefox >/dev/null 2>&1 || return

  log "managed storage repaired while Firefox running — controlled restart"
  user=""
  uid="$(stat -f %u /dev/console 2>/dev/null || true)"
  if [ -n "$uid" ] && [ "$uid" != 0 ]; then
    user="$(id -nu "$uid" 2>/dev/null || true)"
    if [ -n "$user" ]; then
      launchctl asuser "$uid" sudo -u "$user" \
        osascript -e 'tell application "Firefox" to quit' >/dev/null 2>&1 || true
      sleep 5
    fi
  fi
  pkill -x firefox 2>/dev/null || true
  sleep 2
  if [ -n "$user" ]; then
    launchctl asuser "$uid" sudo -u "$user" open -a Firefox >/dev/null 2>&1 || true
  fi
}

case "$MODE" in
  daemon)
    trap 'log "verifier stopped"; exit 0' INT TERM
    log "verifier started (pid $$, interval ${CHECK_INTERVAL}s)"
    while :; do
      run_pass
      maybe_restart
      sleep "$CHECK_INTERVAL" &
      wait $!
    done
    ;;
  repair)
    run_pass
    maybe_restart
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
