#!/bin/bash
# Run the profile UI transaction in the active console user's GUI session.
set -eu

BASE="/Library/Application Support/ChickenBlocker"
APP="$BASE/agent/ChickenBlocker AX Probe.app"
PROFILE="$BASE/expected/org.mozilla.firefox.mobileconfig"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[ "$#" -eq 4 ] || die "usage: $0 credential-fifo admin-user result-path log-path"
FIFO=$1
ADMIN_USER=$2
RESULT=$3
LOG=$4

[ "$(id -u)" -ne 0 ] || die "must run as the GUI console user"
[ -d "$APP" ] || die "root-owned Accessibility helper is missing"
[ "$(stat -f '%Su:%Sg' "$APP")" = root:wheel ] || die "helper is not root-owned"
[ ! -w "$APP" ] || die "helper is writable by the console user"
codesign --verify --deep --strict "$APP" >/dev/null 2>&1 || die "helper signature is invalid"
[ -f "$PROFILE" ] || die "canonical Firefox profile is missing"
[ -p "$FIFO" ] || die "credential channel is not a FIFO"

PROFILE_ID=$(/usr/libexec/PlistBuddy -c 'Print :PayloadIdentifier' "$PROFILE")
PROFILE_NAME=$(/usr/libexec/PlistBuddy -c 'Print :PayloadDisplayName' "$PROFILE")
PROFILE_UUID=$(/usr/libexec/PlistBuddy -c 'Print :PayloadUUID' "$PROFILE")
[ "$PROFILE_ID" = com.chickenblocker.firefox ] || die "unexpected profile identifier"

profile_ready() {
  output=$(/usr/sbin/system_profiler SPConfigurationProfileDataType -json 2>/dev/null || true)
  printf '%s\n' "$output" | grep -Fq "$PROFILE_UUID" &&
    printf '%s\n' "$output" | grep -Fq 'DisablePrivateBrowsing = 1;'
}

pkill -TERM -x "System Settings" >/dev/null 2>&1 || true
pkill -TERM -x SecurityAgent >/dev/null 2>&1 || true
sleep 2

rm -f "$RESULT"
: > "$LOG"
open -n "$APP" --args --install-profile "$PROFILE" "$FIFO" "$RESULT" \
  "$ADMIN_USER" "$LOG" "$PROFILE_NAME" "$PROFILE_ID" repair "$PROFILE_UUID" \
  'DisablePrivateBrowsing = 1;'

deadline=$(( $(date +%s) + 150 ))
while [ ! -s "$RESULT" ] && [ "$(date +%s)" -lt "$deadline" ]; do
  if profile_ready; then
    pkill -TERM -x cb-ax-probe >/dev/null 2>&1 || true
    printf '%s\n' 'submitted=1 external_verification=1' > "$RESULT"
    break
  fi
  sleep 1
done

[ -s "$RESULT" ] || die "profile helper timed out"
cat "$RESULT"
cat "$LOG"
grep -Fq 'submitted=1' "$RESULT" || die "profile helper rejected the transaction"
profile_ready || die "installed profile failed UUID or policy-marker verification"
