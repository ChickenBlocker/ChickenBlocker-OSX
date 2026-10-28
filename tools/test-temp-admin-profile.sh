#!/bin/bash
# Exercise macOS profile authorization with a short-lived local administrator.
set -euo pipefail

SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
ACCOUNT=cb-timed-admin
FULL_NAME="ChickenBlocker Timed Administrator"
TEST_ID=com.chickenblocker.temp-admin-test
TEST_NAME="ChickenBlocker Temporary Admin Test"
LABEL=com.chickenblocker.temp-admin-watchdog
STATE_DIR=/var/db/chickenblocker-temp-admin-test
STATE="$STATE_DIR/state"
REPORT="$STATE_DIR/report"
RUNTIME="/Library/Application Support/ChickenBlocker/bin/test-temp-admin-profile"
WATCH_PLIST="/Library/LaunchDaemons/$LABEL.plist"
TEST_PROFILE="/Users/Shared/ChickenBlocker Temp Admin Test.mobileconfig"
SUDOERS=/etc/sudoers.d/chickenblocker-temp-admin-test
LOG="/Library/Application Support/ChickenBlocker/temp-admin-test.log"
BASE="/Library/Application Support/ChickenBlocker"
VERIFIER_LABEL=com.chickenblocker.verifier
RELEASE_LABEL=com.chickenblocker.release
BREAK_LABEL=com.chickenblocker.breaks
VERIFIER_PLIST="/Library/LaunchDaemons/$VERIFIER_LABEL.plist"
RELEASE_PLIST="/Library/LaunchDaemons/$RELEASE_LABEL.plist"
BREAK_PLIST="/Library/LaunchAgents/$BREAK_LABEL.plist"
SAFARI=/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

console_identity() {
  CONSOLE_USER=$(/usr/bin/stat -f %Su /dev/console)
  CONSOLE_UID=$(/usr/bin/stat -f %u /dev/console)
  [[ -n $CONSOLE_USER && $CONSOLE_USER != root && $CONSOLE_UID != 0 ]] || \
    die "no GUI console user is logged in"
}

profile_output() {
  /usr/bin/profiles show -type configuration -user "$1" 2>/dev/null || true
  /usr/bin/profiles show -type configuration 2>/dev/null || true
}

test_profile_present() {
  profile_output "$1" | /usr/bin/grep -Fq "$TEST_ID"
}

protection_problem() {
  local user=$1 uid=$2 output

  /bin/launchctl print "system/$VERIFIER_LABEL" >/dev/null 2>&1 || {
    printf '%s\n' "verifier LaunchDaemon is not loaded"
    return
  }
  /bin/launchctl print "system/$RELEASE_LABEL" >/dev/null 2>&1 || {
    printf '%s\n' "release LaunchDaemon is not loaded"
    return
  }
  /bin/launchctl print "gui/$uid/$BREAK_LABEL" >/dev/null 2>&1 || {
    printf '%s\n' "break LaunchAgent is not loaded"
    return
  }
  output=$(/bin/launchctl print-disabled system 2>/dev/null || true)
  if printf '%s\n' "$output" | /usr/bin/grep -Eq \
      "\"($VERIFIER_LABEL|$RELEASE_LABEL)\"[[:space:]]*=>[[:space:]]*true"; then
    printf '%s\n' "a ChickenBlocker system service was disabled"
    return
  fi
  output=$(/bin/launchctl print-disabled "gui/$uid" 2>/dev/null || true)
  if printf '%s\n' "$output" | /usr/bin/grep -Eq \
      "\"$BREAK_LABEL\"[[:space:]]*=>[[:space:]]*true"; then
    printf '%s\n' "the break LaunchAgent was disabled"
    return
  fi
  profile_output "$user" | /usr/bin/grep -Fq 'com.chickenblocker.firefox' || {
    printf '%s\n' "the production Firefox profile is absent"
    return
  }
  /usr/local/bin/santactl fileinfo --key Rule "$SAFARI" 2>/dev/null | \
    /usr/bin/grep -Fq 'Blocked (SigningID, Static)' || {
      printf '%s\n' "the static Safari block is absent"
      return
    }
}

repair_protections() {
  local uid=$1

  /bin/launchctl enable "system/$VERIFIER_LABEL" >/dev/null 2>&1 || true
  /bin/launchctl enable "system/$RELEASE_LABEL" >/dev/null 2>&1 || true
  /bin/launchctl print "system/$VERIFIER_LABEL" >/dev/null 2>&1 || \
    /bin/launchctl bootstrap system "$VERIFIER_PLIST" >/dev/null 2>&1 || true
  /bin/launchctl print "system/$RELEASE_LABEL" >/dev/null 2>&1 || \
    /bin/launchctl bootstrap system "$RELEASE_PLIST" >/dev/null 2>&1 || true
  /bin/launchctl kickstart -k "system/$VERIFIER_LABEL" >/dev/null 2>&1 || true
  /bin/launchctl kickstart "system/$RELEASE_LABEL" >/dev/null 2>&1 || true

  /bin/launchctl enable "gui/$uid/$BREAK_LABEL" >/dev/null 2>&1 || true
  /bin/launchctl print "gui/$uid/$BREAK_LABEL" >/dev/null 2>&1 || \
    /bin/launchctl bootstrap "gui/$uid" "$BREAK_PLIST" >/dev/null 2>&1 || true
  /bin/launchctl kickstart -k "gui/$uid/$BREAK_LABEL" >/dev/null 2>&1 || true

  if [[ -x $BASE/bin/cb-bash && -f $BASE/verifier.sh ]]; then
    "$BASE/bin/cb-bash" "$BASE/verifier.sh" repair >> "$LOG" 2>&1 || true
  fi
}

revoke_account() {
  local reason=$1 user=$2 uid=$3 rotated problem

  /bin/mkdir "$STATE_DIR/revoking" >/dev/null 2>&1 || return 0
  /usr/sbin/dseditgroup -o edit -d "$ACCOUNT" -t user admin >/dev/null 2>&1 || true
  rotated=$(/usr/bin/openssl rand -hex 32)
  /usr/bin/dscl . -passwd "/Users/$ACCOUNT" "$rotated" >/dev/null 2>&1 || true
  rotated=
  /usr/bin/pwpolicy -u "$ACCOUNT" disableuser >/dev/null 2>&1 || true
  /usr/bin/pkill -u "$ACCOUNT" >/dev/null 2>&1 || true
  /bin/rm -f "$SUDOERS"

  repair_protections "$uid"
  problem=$(protection_problem "$user" "$uid")
  {
    printf 'ended=%s\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'reason=%s\n' "$reason"
    if [[ -n $problem ]]; then
      printf 'remaining_problem=%s\n' "$problem"
    else
      printf 'protections=healthy\n'
    fi
  } > "$REPORT.new"
  /usr/sbin/chown root:wheel "$REPORT.new"
  /bin/chmod 0600 "$REPORT.new"
  /bin/mv "$REPORT.new" "$REPORT"
  /bin/rm -f "$STATE"
}

watch() {
  [[ $EUID -eq 0 ]] || die "watchdog must run as root"
  [[ -r $STATE ]] || exit 0
  . "$STATE"
  [[ ${deadline:-} =~ ^[0-9]+$ && ${console_uid:-} =~ ^[0-9]+$ ]] || \
    die "invalid watchdog state"

  trap 'revoke_account "watchdog interrupted" "$console_user" "$console_uid"' \
    HUP INT TERM EXIT
  while :; do
    problem=$(protection_problem "$console_user" "$console_uid")
    if [[ -n $problem ]]; then
      revoke_account "protection drift: $problem" "$console_user" "$console_uid"
      trap - EXIT
      exit 0
    fi
    if (( $(/bin/date +%s) >= deadline )); then
      revoke_account "time limit expired" "$console_user" "$console_uid"
      trap - EXIT
      exit 0
    fi
    /bin/sleep 2
  done
}

write_test_profile() {
  /bin/cat > "$TEST_PROFILE.new" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadType</key><string>com.apple.ManagedClient.preferences</string>
      <key>PayloadIdentifier</key><string>com.chickenblocker.temp-admin-test.preferences</string>
      <key>PayloadUUID</key><string>8F126183-37B2-4DE9-A5C2-BC640B80A102</string>
      <key>PayloadVersion</key><integer>1</integer>
      <key>PayloadDisplayName</key><string>Temporary Admin Test Preference</string>
      <key>PayloadContent</key>
      <dict>
        <key>com.chickenblocker.temp-admin-test</key>
        <dict><key>Forced</key><array><dict><key>mcx_preference_settings</key><dict><key>Installed</key><true/></dict></dict></array></dict>
      </dict>
    </dict>
  </array>
  <key>PayloadIdentifier</key><string>com.chickenblocker.temp-admin-test</string>
  <key>PayloadRemovalDisallowed</key><false/>
  <key>PayloadScope</key><string>System</string>
  <key>PayloadType</key><string>Configuration</string>
  <key>PayloadUUID</key><string>8F126183-37B2-4DE9-A5C2-BC640B80A101</string>
  <key>PayloadVersion</key><integer>1</integer>
  <key>PayloadDisplayName</key><string>ChickenBlocker Temporary Admin Test</string>
  <key>PayloadOrganization</key><string>ChickenBlocker</string>
</dict>
</plist>
EOF
  /usr/sbin/chown root:wheel "$TEST_PROFILE.new"
  /bin/chmod 0644 "$TEST_PROFILE.new"
  /bin/mv "$TEST_PROFILE.new" "$TEST_PROFILE"
  /usr/bin/plutil -lint "$TEST_PROFILE" >/dev/null
}

write_watchdog_plist() {
  /bin/cat > "$WATCH_PLIST.new" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$RUNTIME</string><string>--watch</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
  /usr/sbin/chown root:wheel "$WATCH_PLIST.new"
  /bin/chmod 0644 "$WATCH_PLIST.new"
  /bin/mv "$WATCH_PLIST.new" "$WATCH_PLIST"
  /usr/bin/plutil -lint "$WATCH_PLIST" >/dev/null
}

show_password_dialog() {
  local password=$1 message=$2 seconds=$3 script
  script="display dialog \"$message\\nUsername: $ACCOUNT\\nCopy the password below.\" default answer \"$password\" buttons {\"Continue\"} default button \"Continue\" giving up after $seconds with title \"Temporary administrator test\""
  /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" \
    /usr/bin/osascript -e "$script" >/dev/null 2>&1 &
}

open_for_console_user() {
  /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" \
    /usr/bin/open "$1" >/dev/null 2>&1 || true
}

remove_residual_account() {
  /usr/bin/id "$ACCOUNT" >/dev/null 2>&1 || return 0
  [[ -d $STATE_DIR ]] || \
    die "refusing to modify pre-existing account without test state: $ACCOUNT"
  /usr/sbin/dseditgroup -o edit -d "$ACCOUNT" -t user admin >/dev/null 2>&1 || true
  # Deleting an enabled, non-admin account avoids leaving disable state behind
  # when this fixed test short name is reused on a later run.
  /usr/bin/pwpolicy -u "$ACCOUNT" enableuser >/dev/null 2>&1 || true
  /usr/sbin/sysadminctl -deleteUser "$ACCOUNT" -secure >/dev/null 2>&1 || true
  if /usr/bin/dscl . -read "/Users/$ACCOUNT" >/dev/null 2>&1; then
    /usr/bin/dscl . -delete "/Users/$ACCOUNT" >/dev/null 2>&1 || true
  fi
  if /usr/bin/id "$ACCOUNT" >/dev/null 2>&1; then
    /usr/bin/pwpolicy -u "$ACCOUNT" disableuser >/dev/null 2>&1 || true
    die "disabled residual account could not be deleted: $ACCOUNT"
  fi
  /bin/rm -rf "/Users/$ACCOUNT"
}

cleanup_artifacts() {
  /bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
  /bin/rm -f "$WATCH_PLIST" "$SUDOERS" "$RUNTIME" "$TEST_PROFILE"
}

emergency_cleanup() {
  local rc=$?
  trap - EXIT
  if [[ ${CLEANUP_ARMED:-0} == 1 ]]; then
    revoke_account "test script exited unexpectedly" "$CONSOLE_USER" "$CONSOLE_UID" || true
    cleanup_artifacts
    if test_profile_present "$CONSOLE_USER"; then
      /usr/bin/profiles remove -identifier "$TEST_ID" >/dev/null 2>&1 || true
    fi
    remove_residual_account || true
  fi
  exit "$rc"
}

root_test() {
  local duration=$1 deadline password problem installed=0 removed=0 reason
  [[ $(/usr/bin/uname -s) == Darwin && $EUID -eq 0 ]] || \
    die "test requires macOS root"
  [[ $duration =~ ^[0-9]+$ ]] && (( duration >= 60 && duration <= 300 )) || \
    die "duration must be between 60 and 300 seconds"
  console_identity
  problem=$(protection_problem "$CONSOLE_USER" "$CONSOLE_UID")
  [[ -z $problem ]] || die "preflight failed: $problem"

  /bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
  [[ ! -e $STATE || -e $STATE_DIR/revoking ]] || die "another test is active"
  remove_residual_account
  if test_profile_present "$CONSOLE_USER"; then
    die "disposable test profile is already installed; remove $TEST_NAME first"
  fi
  /bin/rm -rf "$STATE_DIR"
  /usr/bin/install -d -o root -g wheel -m 0700 "$STATE_DIR"
  /usr/bin/install -o root -g wheel -m 0700 "$SELF" "$RUNTIME"
  write_test_profile
  write_watchdog_plist

  deadline=$(( $(/bin/date +%s) + duration ))
  {
    printf 'deadline=%q\n' "$deadline"
    printf 'console_user=%q\n' "$CONSOLE_USER"
    printf 'console_uid=%q\n' "$CONSOLE_UID"
  } > "$STATE"
  /usr/sbin/chown root:wheel "$STATE"
  /bin/chmod 0600 "$STATE"

  CLEANUP_ARMED=1
  trap emergency_cleanup EXIT
  password=$(/usr/bin/openssl rand -hex 12)
  /usr/sbin/sysadminctl -addUser "$ACCOUNT" -fullName "$FULL_NAME" \
    -shell /bin/zsh -password "$password" -home "/Users/$ACCOUNT" -admin >/dev/null
  /usr/bin/pwpolicy -u "$ACCOUNT" enableuser >/dev/null
  /usr/bin/dscl . -authonly "$ACCOUNT" "$password"
  /usr/sbin/dseditgroup -o checkmember -m "$ACCOUNT" admin | \
    /usr/bin/grep -Fq 'yes' || die "temporary account is not an administrator"
  printf '%s ALL=(ALL) !ALL\n' "$ACCOUNT" > "$SUDOERS"
  /usr/sbin/chown root:wheel "$SUDOERS"
  /bin/chmod 0440 "$SUDOERS"
  /usr/sbin/visudo -cf "$SUDOERS" >/dev/null
  /usr/sbin/visudo -c >/dev/null

  /bin/launchctl bootstrap system "$WATCH_PLIST"
  /bin/launchctl print "system/$LABEL" >/dev/null
  open_for_console_user "$TEST_PROFILE"
  show_password_dialog "$password" \
    "Install only the '$TEST_NAME' profile, using this credential when macOS asks." \
    "$duration"

  while (( $(/bin/date +%s) < deadline )) && [[ -e $STATE ]]; do
    if test_profile_present "$CONSOLE_USER"; then
      installed=1
      break
    fi
    /bin/sleep 2
  done
  if (( installed == 1 )); then
    remaining=$(( deadline - $(/bin/date +%s) ))
    (( remaining > 0 )) || remaining=1
    open_for_console_user 'x-apple.systempreferences:com.apple.Profiles-Settings.extension'
    show_password_dialog "$password" \
      "Installation succeeded. Now remove only the '$TEST_NAME' profile." \
      "$remaining"
    while (( $(/bin/date +%s) < deadline )) && [[ -e $STATE ]]; do
      if ! test_profile_present "$CONSOLE_USER"; then
        removed=1
        break
      fi
      /bin/sleep 2
    done
  fi
  password=

  if (( installed == 0 )); then
    reason="test profile was not installed before timeout"
  elif (( removed == 0 )); then
    reason="test profile was installed but not removed before timeout"
  else
    reason="test profile install and removal succeeded"
  fi
  revoke_account "$reason" "$CONSOLE_USER" "$CONSOLE_UID"
  cleanup_artifacts

  if test_profile_present "$CONSOLE_USER"; then
    /usr/bin/profiles remove -identifier "$TEST_ID" >/dev/null 2>&1 || true
  fi
  remove_residual_account
  CLEANUP_ARMED=0
  trap - EXIT
  printf '\nTemporary administrator profile test:\n'
  /bin/cat "$REPORT"
  if test_profile_present "$CONSOLE_USER"; then
    die "disposable profile remains installed: $TEST_ID"
  fi
  problem=$(protection_problem "$CONSOLE_USER" "$CONSOLE_UID")
  [[ -z $problem ]] || die "post-test protection problem: $problem"
  (( installed == 1 && removed == 1 )) || exit 1
}

case ${1:-} in
  --watch)
    watch
    ;;
  --root)
    root_test "${2:-120}"
    ;;
  ''|*[!0-9]*)
    die "usage: $SELF [60-300 seconds]"
    ;;
  *)
    duration=$1
    if [[ $EUID -eq 0 ]]; then
      root_test "$duration"
    elif [[ $(/usr/bin/id -un) == svc-admin ]]; then
      exec /usr/bin/sudo "$SELF" --root "$duration"
    else
      printf '%s\n' \
        'Authenticate as svc-admin, then authenticate sudo with the same password.' \
        'The generated temporary password appears only in the macOS dialogs.'
      printf -v command '/usr/bin/sudo %q --root %q' "$SELF" "$duration"
      exec /usr/bin/su - svc-admin -c "$command"
    fi
    ;;
esac
