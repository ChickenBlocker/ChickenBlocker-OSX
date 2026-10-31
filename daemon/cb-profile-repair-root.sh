#!/bin/bash
# Coordinate an authenticated profile repair without retaining an admin secret.
set -eu

BASE="/Library/Application Support/ChickenBlocker"
RUNNER="$BASE/agent/profile-repair-user.sh"
ACCOUNT=cb-policy-repair
MARKER=/var/db/chickenblocker-policy-repair
LOCK="$BASE/.profile-repair-lock"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

account_exists() {
  dscl . -read "/Users/$ACCOUNT" >/dev/null 2>&1
}

revoke_account() {
  account_exists || return 0
  [ -f "$MARKER" ] || die "refusing to revoke unmarked account $ACCOUNT"
  dseditgroup -o edit -d "$ACCOUNT" -t user admin >/dev/null 2>&1 || true
  rotated=$(openssl rand -hex 32)
  dscl . -passwd "/Users/$ACCOUNT" "$rotated" >/dev/null 2>&1 || true
  rotated=
  pwpolicy -u "$ACCOUNT" disableuser >/dev/null 2>&1 || true
  pkill -u "$ACCOUNT" >/dev/null 2>&1 || true
}

cleanup() {
  rc=$?
  trap - EXIT INT TERM
  [ -z "${writer:-}" ] || kill -KILL "$writer" >/dev/null 2>&1 || true
  revoke_account
  [ -z "${tmp:-}" ] || rm -rf "$tmp"
  rmdir "$LOCK" >/dev/null 2>&1 || true
  password=
  exit "$rc"
}

create_account() {
  uid=503
  while dscl . -search /Users UniqueID "$uid" 2>/dev/null | grep -q .; do
    uid=$((uid + 1))
    [ "$uid" -lt 600 ] || die "no local UID available for repair identity"
  done
  dscl . -create "/Users/$ACCOUNT"
  dscl . -create "/Users/$ACCOUNT" UniqueID "$uid"
  dscl . -create "/Users/$ACCOUNT" PrimaryGroupID 20
  dscl . -create "/Users/$ACCOUNT" RealName "ChickenBlocker Policy Repair"
  dscl . -create "/Users/$ACCOUNT" UserShell /usr/bin/false
  dscl . -create "/Users/$ACCOUNT" NFSHomeDirectory /var/empty
  dscl . -create "/Users/$ACCOUNT" IsHidden 1
  printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
  chown root:wheel "$MARKER"
  chmod 0600 "$MARKER"
}

[ "$(id -u)" -eq 0 ] || die "root required"
[ "${1:-}" != --revoke ] || {
  revoke_account
  exit 0
}
[ "$#" -eq 0 ] || die "usage: $0 [--revoke]"
[ -x "$RUNNER" ] || die "user-session repair runner is missing"
mkdir "$LOCK" 2>/dev/null || die "another profile repair is active"
trap cleanup EXIT INT TERM

CONSOLE_USER=$(stat -f %Su /dev/console)
CONSOLE_UID=$(stat -f %u /dev/console)
[ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != root ] && [ "$CONSOLE_UID" != 0 ] || \
  die "no GUI console user is logged in"
CONSOLE_HOME=$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')
[ -n "$CONSOLE_HOME" ] || die "console-user home could not be resolved"

if account_exists; then
  [ -f "$MARKER" ] || die "refusing to use unmarked account $ACCOUNT"
else
  create_account
fi

password=$(openssl rand -hex 24)
pwpolicy -u "$ACCOUNT" enableuser >/dev/null
dscl . -passwd "/Users/$ACCOUNT" "$password"
dseditgroup -o edit -a "$ACCOUNT" -t user admin >/dev/null
dscl . -authonly "$ACCOUNT" "$password" || die "repair identity authentication failed"

tmp=$(mktemp -d /var/tmp/cb-profile-repair.XXXXXX)
chown "$CONSOLE_USER":staff "$tmp"
chmod 0700 "$tmp"
fifo="$tmp/credential"
result="$tmp/result"
logfile="$tmp/transaction.log"
mkfifo -m 0600 "$fifo"
chown "$CONSOLE_USER":staff "$fifo"

(printf '%s\n' "$password" > "$fifo") &
writer=$!
set +e
launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" \
  env HOME="$CONSOLE_HOME" "$RUNNER" "$fifo" "$ACCOUNT" "$result" "$logfile"
status=$?
set -e
kill -KILL "$writer" >/dev/null 2>&1 || true
wait "$writer" 2>/dev/null || true
writer=
[ "$status" -eq 0 ] || die "console-user profile transaction failed"

prefs="/Library/Managed Preferences/$CONSOLE_USER/org.mozilla.firefox.plist"
deadline=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  [ "$(plutil -extract EnterprisePoliciesEnabled raw -o - "$prefs" 2>/dev/null || true)" = true ] &&
    [ "$(plutil -extract DisablePrivateBrowsing raw -o - "$prefs" 2>/dev/null || true)" = true ] && break
  sleep 1
done
[ "$(plutil -extract EnterprisePoliciesEnabled raw -o - "$prefs" 2>/dev/null || true)" = true ] || \
  die "EnterprisePoliciesEnabled did not materialize"
[ "$(plutil -extract DisablePrivateBrowsing raw -o - "$prefs" 2>/dev/null || true)" = true ] || \
  die "DisablePrivateBrowsing did not materialize"
printf '%s\n' "profile_repair=verified user=$CONSOLE_USER"
