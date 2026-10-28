#!/bin/bash
# Test whether the granted helper can type a user-supplied administrator
# credential into the combined SecurityAgent authorization window.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
APP="$HOME/Applications/ChickenBlocker AX Probe.app"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cb-auth-input.XXXXXX")
FIFO="$TMP/credential"
RESULT="$TMP/result"
LOG="$TMP/inject.log"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

restart_settings() {
  local old_pid new_pid deadline
  old_pid=$(/usr/bin/pgrep -x "System Settings" 2>/dev/null || true)
  /usr/bin/pkill -TERM -x "System Settings" >/dev/null 2>&1 || true
  /usr/bin/pkill -TERM -x SecurityAgent >/dev/null 2>&1 || true
  deadline=$(( $(/bin/date +%s) + 10 ))
  while /usr/bin/pgrep -x "System Settings" >/dev/null 2>&1 && \
      (( $(/bin/date +%s) < deadline )); do
    /bin/sleep 1
  done
  /usr/bin/pgrep -x "System Settings" >/dev/null 2>&1 && \
    die "System Settings did not terminate"
  /usr/bin/open 'x-apple.systempreferences:com.apple.Profiles-Settings.extension'
  /bin/sleep 3
  new_pid=$(/usr/bin/pgrep -x "System Settings" 2>/dev/null || true)
  [[ -n $new_pid && $new_pid != "$old_pid" ]] || \
    die "System Settings did not restart with a new PID"
  printf 'settings_restart=%s->%s\n' "${old_pid:-none}" "$new_pid"
}

cleanup() {
  unset credential
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

CB_INSTALL_ONLY=1 "$REPO/tools/test-allowed-profile-removal.sh"
restart_settings

identity=$(/usr/bin/security find-identity -p codesigning 2>/dev/null | \
  /usr/bin/sed -n 's/^[[:space:]]*[0-9]*)[[:space:]]*[A-Fa-f0-9]*[[:space:]]*"\(.*\)".*$/\1/p' | \
  /usr/bin/head -1)
[[ -n $identity ]] || die "no stable code-signing identity"
/bin/rm -rf "$APP.new"
/bin/mkdir -p "$APP.new/Contents/MacOS"
/usr/bin/xcrun swiftc "$REPO/agent/cb-ax-probe.swift" -o "$APP.new/Contents/MacOS/cb-ax-probe"
/bin/cp "$REPO/agent/cb-ax-probe-Info.plist" "$APP.new/Contents/Info.plist"
/usr/bin/codesign --force --sign "$identity" "$APP.new" >/dev/null 2>&1
/bin/rm -rf "$APP"
/bin/mv "$APP.new" "$APP"

/usr/bin/mkfifo -m 0600 "$FIFO"
: > "$LOG"
credential=$(/usr/bin/osascript -e \
  'text returned of (display dialog "Enter the svc-admin credential for this disposable profile test. It will be sent only through an in-memory pipe." default answer "" with hidden answer buttons {"Cancel", "Continue"} default button "Continue" with title "ChickenBlocker Device Management test")')
[[ -n $credential ]] || die "empty credential"

/usr/bin/osascript -e \
  'display dialog "After clicking Begin, select ChickenBlocker Temporary Admin Test in Device Management, click -, then Remove. Do not type in SecurityAgent; wait for the helper." buttons {"Begin"} default button "Begin" with title "Accessibility credential-input test"' \
  >/dev/null 2>&1

/usr/bin/open "$APP" --args --inject-auth "$FIFO" "$RESULT" svc-admin "$LOG" "ChickenBlocker Temporary Admin Test"
(printf '%s\n' "$credential" > "$FIFO") 2>/dev/null &
writer=$!
unset credential

/usr/bin/open 'x-apple.systempreferences:com.apple.Profiles-Settings.extension'
printf '%s\n' "injector_armed=1"

deadline=$(( $(/bin/date +%s) + 120 ))
while ! /usr/bin/grep -Fq 'submitted=' "$RESULT" 2>/dev/null && \
    (( $(/bin/date +%s) < deadline )); do
  /bin/sleep 1
done
wait "$writer" 2>/dev/null || true
if ! /usr/bin/grep -Fq 'submitted=' "$RESULT" 2>/dev/null; then
  [[ ! -f $LOG ]] || /bin/cat "$LOG"
  die "helper produced no final result"
fi
/bin/cat "$RESULT"
[[ ! -f $LOG ]] || /bin/cat "$LOG"

if /usr/sbin/system_profiler SPConfigurationProfileDataType -json 2>/dev/null | \
    /usr/bin/grep -Fq 'com.chickenblocker.temp-admin-test'; then
  die "credential submission did not remove the disposable profile"
fi
restart_settings
printf '%s\n' "result=synthetic credential input accepted"
printf '%s\n' "authorization_cache_reset=System Settings restarted"
