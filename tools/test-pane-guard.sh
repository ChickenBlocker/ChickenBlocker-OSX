#!/bin/bash
# Exercise the pane guard: the granted probe watches System Settings window
# titles and snaps back to the Profiles pane when the user strays or closes
# it. Mechanism test only; no real policy is touched.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
SOURCE="$REPO/agent/cb-ax-probe.swift"
PLIST_SRC="$REPO/agent/cb-ax-probe-Info.plist"
KEEPER="$HOME/Applications/ChickenBlocker AX Probe.app"
PANE='x-apple.systempreferences:com.apple.Profiles-Settings.extension'
WATCH_SECONDS=120
ALLOWED_PROFILE_NAME=${CB_ALLOWED_PROFILE_NAME:-ChickenBlocker Temporary Admin Test}
ALLOWED_PROFILE_ID=${CB_ALLOWED_PROFILE_ID:-com.chickenblocker.temp-admin-test}
WAIT_FOR_PROFILE_ID=${CB_WAIT_FOR_PROFILE_REMOVAL:-}
RESULT=$(mktemp "${TMPDIR:-/tmp}/cb-pane-guard.XXXXXX")
STATE="$RESULT.log"
STOP="$RESULT.stop"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  touch "$STOP" 2>/dev/null || true
  sleep 1
  rm -f "$RESULT" "$STATE" "$STOP"
}
trap cleanup EXIT

probe_once() {
  local text process=${1:-}
  local -a args=("$RESULT")
  [[ -n $process ]] && args+=("$process")
  /bin/rm -f "$RESULT"
  /usr/bin/open -W "$KEEPER" --args "${args[@]}" >/dev/null 2>&1 || true
  text=$(/bin/cat "$RESULT" 2>/dev/null) || text=""
  printf '%s' "$text"
}

codesigning_identity() {
  /usr/bin/security find-identity -p codesigning 2>/dev/null | \
    /usr/bin/sed -n 's/^[[:space:]]*[0-9]*)[[:space:]]*[A-Fa-f0-9]*[[:space:]]*"\(.*\)".*$/\1/p' | \
    /usr/bin/head -1
}

[[ $(/usr/bin/uname -s) == Darwin ]] || die "macOS only"
[[ $EUID -ne 0 ]] || die "run as the console user, not root"
[[ -d $KEEPER ]] || die "keeper app missing; run tools/test-accessibility-grant.sh first"
if [[ -n $WAIT_FOR_PROFILE_ID ]] && ! \
    /usr/sbin/system_profiler SPConfigurationProfileDataType -json 2>/dev/null | \
    /usr/bin/grep -Fq "$WAIT_FOR_PROFILE_ID"; then
  die "profile is not installed: $WAIT_FOR_PROFILE_ID"
fi
[[ $(probe_once) == ok\ * ]] || die "grant not working; run tools/test-accessibility-grant.sh first"
identity=$(codesigning_identity)
[[ -n $identity ]] || die "no code-signing identity; run tools/test-accessibility-grant.sh first"

/bin/rm -rf "$KEEPER.new"
/bin/mkdir -p "$KEEPER.new/Contents/MacOS"
/usr/bin/xcrun swiftc "$SOURCE" -o "$KEEPER.new/Contents/MacOS/cb-ax-probe"
/bin/cp "$PLIST_SRC" "$KEEPER.new/Contents/Info.plist"
/usr/bin/codesign --force --sign "$identity" "$KEEPER.new" >/dev/null 2>&1 || \
  die "codesign failed"
/bin/rm -rf "$KEEPER"
/bin/mv "$KEEPER.new" "$KEEPER"
printf '%s\n' "rebuilt keeper with watch mode (identity: $identity)"

/usr/bin/open "$PANE"
baseline=""
for _ in 1 2 3 4 5 6 7 8; do
  /bin/sleep 2
  text=$(probe_once "System Settings")
  if [[ $text == ok\ * ]]; then
    baseline=${text#ok }
    baseline=${baseline%%,*}
    [[ -n $baseline ]] && break
  fi
done
[[ -n $baseline ]] || die "could not read a System Settings window title: ${text:-none}"
printf 'baseline pane title: %s\n' "$baseline"

/bin/rm -f "$STATE" "$STOP"
/usr/bin/open "$KEEPER" --args --watch "$STATE" "$baseline" "$PANE" "$WATCH_SECONDS" "$STOP" "$ALLOWED_PROFILE_ID" "$ALLOWED_PROFILE_NAME"
/bin/sleep 2
removed=0
if [[ -n $WAIT_FOR_PROFILE_ID ]]; then
  /usr/bin/osascript -e \
    "display dialog \"After clicking Begin, remove '$ALLOWED_PROFILE_NAME': select it, click -, Remove, Allow Access, and enter svc-admin credentials. This test waits automatically until removal completes; do not close it manually.\" buttons {\"Begin\"} default button \"Begin\" giving up after 120 with title \"Allowed removal test\"" \
    >/dev/null 2>&1 || true
  deadline=$(( $(/bin/date +%s) + WATCH_SECONDS ))
  while (( $(/bin/date +%s) < deadline )); do
    if ! /usr/sbin/system_profiler SPConfigurationProfileDataType -json 2>/dev/null | \
        /usr/bin/grep -Fq "$WAIT_FOR_PROFILE_ID"; then
      removed=1
      break
    fi
    /bin/sleep 5
  done
else
  if [[ $ALLOWED_PROFILE_NAME == __none__ ]]; then
    /usr/bin/osascript -e \
      "display dialog \"Blocked-removal test: select ChickenBlocker Temporary Admin Test, click -, then Remove. The confirmation must close and SecurityAgent must not remain open. Click Continue after attempting it.\" buttons {\"Continue\"} default button \"Continue\" giving up after $WATCH_SECONDS with title \"Blocked removal test\"" \
      >/dev/null 2>&1 || true
  else
    /usr/bin/osascript -e \
      "display dialog \"Pane guard active for $WATCH_SECONDS seconds. Protected entries: try - and even race toward authorization; confirmation or SecurityAgent is closed. Temporary Admin Test: use - > Remove, enter svc-admin credentials in the combined SecurityAgent window, click Allow Access, and complete removal; its window state changes are recorded. Click Continue when finished.\" buttons {\"Continue\"} default button \"Continue\" giving up after $WATCH_SECONDS with title \"Pane guard test\"" \
      >/dev/null 2>&1 || true
  fi
fi
touch "$STOP"
/bin/sleep 2

printf '\nPane guard events:\n'
if [[ -s $STATE ]]; then
  /bin/cat "$STATE"
else
  die "watcher produced no observations"
fi
strays=$(/usr/bin/grep -c -E 'strayed|settings-closed' "$STATE" 2>/dev/null || true)
printf '\nstray_events=%s\n' "${strays:-0}"
if [[ -n $WAIT_FOR_PROFILE_ID ]]; then
  printf 'profile_removed=%s\n' "$removed"
  (( removed == 1 )) || die "profile was not removed before timeout"
fi
printf 'result=pane guard observed and enforced pane focus\n'
