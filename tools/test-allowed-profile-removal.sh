#!/bin/bash
# Prove absent -> installed -> guarded removal -> absent for the disposable
# profile, recording authorization-window state changes during removal.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
PROFILE="/Users/Shared/ChickenBlocker Temp Admin Test Fresh.mobileconfig"
PROFILE_ID=com.chickenblocker.temp-admin-test

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

profile_present() {
  /usr/sbin/system_profiler SPConfigurationProfileDataType -json 2>/dev/null | \
    /usr/bin/grep -Fq "$PROFILE_ID"
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

installed_by_test=0
if ! profile_present; then
  uuid1=$(/usr/bin/uuidgen)
  uuid2=$(/usr/bin/uuidgen)
  /usr/bin/sed -n "/^write_test_profile/,/^}/p" "$REPO/tools/test-temp-admin-profile.sh" | \
    /usr/bin/sed -n "/<<'EOF'/,/^EOF$/p" | /usr/bin/sed '1d;$d' | \
    /usr/bin/sed \
      "s/8F126183-37B2-4DE9-A5C2-BC640B80A102/$uuid2/g; s/8F126183-37B2-4DE9-A5C2-BC640B80A101/$uuid1/g" \
      > "$PROFILE"
  /usr/bin/plutil -lint "$PROFILE" >/dev/null

  /usr/bin/open 'x-apple.systempreferences:com.apple.Profiles-Settings.extension'
  /usr/bin/open -R "$PROFILE"
  /usr/bin/osascript -e \
    "display dialog \"Install the disposable profile first: in Device Management click +, choose '$PROFILE', click Install, authenticate with svc-admin, and wait until it says Installed. Then click Continue.\" buttons {\"Continue\"} default button \"Continue\" giving up after 300 with title \"Install disposable profile\"" \
    >/dev/null 2>&1 || true

  deadline=$(( $(/bin/date +%s) + 60 ))
  while (( $(/bin/date +%s) < deadline )); do
    profile_present && break
    /bin/sleep 3
  done
  profile_present || die "installation was not observed; removal test did not start"
  installed_by_test=1
fi
printf '%s\n' "install_verified=1"

if [[ ${CB_INSTALL_ONLY:-0} == 1 ]]; then
  exit 0
fi

if [[ ${CB_TEST_BLOCKED_REMOVAL:-0} == 1 ]]; then
  CB_ALLOWED_PROFILE_NAME=__none__ CB_ALLOWED_PROFILE_ID=__none__ \
    "$REPO/tools/test-pane-guard.sh"
  profile_present || die "blocked-removal test failed: profile was removed"
  if /usr/bin/pgrep -x SecurityAgent >/dev/null 2>&1; then
    die "blocked-removal test failed: SecurityAgent is still running"
  fi
  printf '%s\n' "blocked_removal_preserved=1"
  exit 0
fi

CB_WAIT_FOR_PROFILE_REMOVAL="$PROFILE_ID" \
  "$REPO/tools/test-pane-guard.sh"

profile_present && die "profile still installed after guarded removal"
restart_settings
printf '%s\n' "authorization_cache_reset=System Settings restarted"
if (( installed_by_test == 1 )); then
  printf '%s\n' "lifecycle=absent -> installed -> removed"
else
  printf '%s\n' "lifecycle=installed -> removed"
fi
