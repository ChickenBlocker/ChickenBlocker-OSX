#!/bin/bash
# Create a short-lived administrator and use it for guarded profile updates.
set -euo pipefail

SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
REPO=$(cd "$(dirname "$0")/.." && pwd)
ACCOUNT=cb-policy-update-test
FULL_NAME="ChickenBlocker Policy Update Test"
MARKER=/var/db/chickenblocker-policy-update-test
SVC_ADMIN_USER=${CB_TEST_BOOTSTRAP_ADMIN:-svc-admin}
ROOT_AX_APP="/Library/Application Support/ChickenBlocker/agent/ChickenBlocker AX Probe.app"
VBOX_FILENAME=VirtualBox-7.2.22-175245-macOSArm64.dmg
RUN_VIRTUALBOX=0
VBOX_DMG=
ACCOUNT_ONLY=${CB_TEST_ACCOUNT_ONLY:-0}
DEFER_DELETE=${CB_TEST_DEFER_DELETE:-0}
PRODUCTION_REPAIR=0
PRODUCTION_REMOVE_ONLY=0
PRODUCTION_PROFILE="/Library/Application Support/ChickenBlocker/expected/org.mozilla.firefox.mobileconfig"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

account_exists() {
  /usr/bin/dscl . -read "/Users/$ACCOUNT" >/dev/null 2>&1
}

remove_account() {
  account_exists || {
    /bin/rm -f "$MARKER"
    return 0
  }
  [[ -f $MARKER ]] || die "refusing to remove unmarked account: $ACCOUNT"
  /usr/sbin/sysadminctl -secureTokenStatus "$ACCOUNT" 2>&1 | \
    /usr/bin/grep -Fq 'Secure token is ENABLED' && \
    die "refusing deletion of secure-token account: $ACCOUNT"
  [[ -n ${svc_credential:-} ]] || \
    die "$SVC_ADMIN_USER credential is required to delete the temporary account"
  [[ -n ${TEST_CONSOLE_UID:-} && -n ${TEST_CONSOLE_USER:-} ]] || \
    die "console user context is required to delete the temporary account"
  /usr/bin/pkill -u "$ACCOUNT" >/dev/null 2>&1 || true
  /usr/sbin/dseditgroup -o edit -d "$ACCOUNT" -t user admin >/dev/null 2>&1 || true
  /bin/launchctl asuser "$TEST_CONSOLE_UID" /usr/bin/sudo -u "$TEST_CONSOLE_USER" \
    /usr/bin/dscl -u "$SVC_ADMIN_USER" -P "$svc_credential" . \
    -delete "/Users/$ACCOUNT" >/dev/null 2>&1 || true
  local deadline=$(( $(/bin/date +%s) + 10 ))
  while account_exists && (( $(/bin/date +%s) < deadline )); do
    /bin/sleep 1
  done
  account_exists && die "temporary account remains: $ACCOUNT"
  /bin/rm -rf "/Users/$ACCOUNT"
  /bin/rm -f "$MARKER"
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  [[ -z ${writer:-} ]] || /bin/kill -KILL "$writer" >/dev/null 2>&1 || true
  [[ -z ${mount_point:-} ]] || /usr/bin/hdiutil detach "$mount_point" >/dev/null 2>&1 || true
  if [[ $EUID -eq 0 ]]; then
    if (( DEFER_DELETE == 0 )); then
      remove_account || rc=1
    fi
    [[ -z ${tmp:-} ]] || /bin/rm -rf "$tmp"
  fi
  unset password
  unset svc_credential
  exit "$rc"
}

create_account() {
  local uid=503
  while /usr/bin/dscl . -search /Users UniqueID "$uid" 2>/dev/null | \
      /usr/bin/grep -q .; do
    uid=$(( uid + 1 ))
    (( uid < 600 )) || die "no unused local UID available below 600"
  done

  /usr/bin/dscl . -create "/Users/$ACCOUNT"
  /usr/bin/dscl . -create "/Users/$ACCOUNT" UniqueID "$uid"
  /usr/bin/dscl . -create "/Users/$ACCOUNT" PrimaryGroupID 20
  /usr/bin/dscl . -create "/Users/$ACCOUNT" RealName "$FULL_NAME"
  /usr/bin/dscl . -create "/Users/$ACCOUNT" UserShell /bin/zsh
  /usr/bin/dscl . -create "/Users/$ACCOUNT" NFSHomeDirectory "/Users/$ACCOUNT"
  /usr/bin/dscl . -passwd "/Users/$ACCOUNT" "$password"
  /usr/sbin/dseditgroup -o edit -a "$ACCOUNT" -t user admin
  /bin/mkdir -p "/Users/$ACCOUNT"
  /usr/sbin/chown -R "$ACCOUNT":staff "/Users/$ACCOUNT"
  /bin/chmod 0700 "/Users/$ACCOUNT"
}

install_virtualbox() {
  local app_signature signature command
  [[ -f $VBOX_DMG ]] || die "VirtualBox image not found: $VBOX_DMG"
  [[ $(/usr/bin/uname -m) == arm64 ]] || die "the selected VirtualBox image is Arm64-only"
  mount_point=$(/usr/bin/hdiutil attach -readonly -nobrowse "$VBOX_DMG" | \
    /usr/bin/sed -n 's#^.*\(/Volumes/.*\)$#\1#p' | /usr/bin/tail -1)
  [[ -n $mount_point && -f $mount_point/VirtualBox.pkg ]] || \
    die "VirtualBox.pkg was not found in the mounted image"
  signature=$(/usr/sbin/pkgutil --check-signature "$mount_point/VirtualBox.pkg")
  printf '%s\n' "$signature" | /usr/bin/grep -Fq \
    'Developer ID Installer: Oracle America, Inc. (VB5E2TV963)' || \
    die "VirtualBox package has an unexpected signer"
  printf '%s\n' "$signature" | /usr/bin/grep -Fq 'Notarization: trusted' || \
    die "VirtualBox package is not notarized"

  printf -v command '/usr/bin/sudo -S -k -p "" /usr/sbin/installer -pkg %q -target /' \
    "$mount_point/VirtualBox.pkg"
  printf '%s\n' "$password" | /usr/bin/su - "$ACCOUNT" -c "$command"
  [[ -d /Applications/VirtualBox.app ]] || die "VirtualBox application was not installed"
  app_signature=$(/usr/bin/codesign -dv --verbose=4 /Applications/VirtualBox.app 2>&1)
  [[ $app_signature == *'TeamIdentifier=VB5E2TV963'* ]] || \
    die "installed VirtualBox application has an unexpected Team ID"
  /usr/sbin/spctl -a -vv /Applications/VirtualBox.app 2>&1 | \
    /usr/bin/grep -F 'source=Notarized Developer ID' >/dev/null || \
    die "installed VirtualBox application failed notarized Gatekeeper assessment"
  printf '%s\n' \
    "virtualbox=installed with temporary administrator credentials" \
    "virtualbox_note=macOS may separately require manual approval before Oracle system software can run"
}

root_test() {
  local console_user console_uid console_home status
  [[ $EUID -eq 0 && $(/usr/bin/uname -s) == Darwin ]] || die "root phase requires macOS root"
  console_user=$(/usr/bin/stat -f %Su /dev/console)
  console_uid=$(/usr/bin/stat -f %u /dev/console)
  [[ -n $console_user && $console_user != root && $console_uid != 0 ]] || \
    die "no GUI console user is logged in"
  console_home=$(/usr/bin/dscl . -read "/Users/$console_user" NFSHomeDirectory | \
    /usr/bin/sed 's/^NFSHomeDirectory: //')
  TEST_CONSOLE_USER=$console_user
  TEST_CONSOLE_UID=$console_uid
  [[ -n $console_home ]] || die "could not resolve console-user home"
  if (( RUN_VIRTUALBOX == 1 )) && [[ -z $VBOX_DMG ]]; then
    VBOX_DMG=$console_home/Downloads/$VBOX_FILENAME
  fi
  [[ -d $ROOT_AX_APP ]] || \
    die "run tools/test-accessibility-grant.sh --install-root as $console_user first"

  if (( DEFER_DELETE == 1 )); then
    account_exists && die "marked temporary account must be removed before the root phase"
  else
    remove_account
  fi
  tmp=$(/usr/bin/mktemp -d /var/tmp/cb-policy-update.XXXXXX)
  /bin/chmod 0711 "$tmp"
  credential_fifo=$tmp/credential
  /usr/bin/mkfifo -m 0600 "$credential_fifo"
  /usr/sbin/chown "$console_user":staff "$credential_fifo"
  password=$(/usr/bin/openssl rand -hex 20)
  printf 'created=%s\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
  /usr/sbin/chown root:wheel "$MARKER"
  /bin/chmod 0600 "$MARKER"
  trap cleanup EXIT INT TERM

  create_account
  /usr/bin/dscl . -authonly "$ACCOUNT" "$password"
  /usr/sbin/dseditgroup -o checkmember -m "$ACCOUNT" admin | \
    /usr/bin/grep -Fq 'yes' || die "temporary account is not an administrator"
  /usr/sbin/sysadminctl -secureTokenStatus "$ACCOUNT" 2>&1 | \
    /usr/bin/grep -Fq 'Secure token is DISABLED' || \
    die "temporary account unexpectedly received a secure token"

  if (( ACCOUNT_ONLY == 1 )); then
    printf '%s\n' "account_lifecycle=tokenless temporary administrator created and authenticated"
    return 0
  fi

  (printf '%s\n' "$password" > "$credential_fifo") &
  writer=$!
  set +e
  if (( PRODUCTION_REMOVE_ONLY == 1 )); then
    /bin/launchctl asuser "$console_uid" /usr/bin/sudo -u "$console_user" \
      /usr/bin/env HOME="$console_home" CB_AX_APP="$ROOT_AX_APP" \
      CB_TEST_ADMIN_USER="$ACCOUNT" CB_TEST_CREDENTIAL_FIFO="$credential_fifo" \
      "$REPO/tools/test-accessibility-profile-install.sh" --cleanup-only "$PRODUCTION_PROFILE"
  elif (( PRODUCTION_REPAIR == 1 )); then
    /bin/launchctl asuser "$console_uid" /usr/bin/sudo -u "$console_user" \
      /usr/bin/env HOME="$console_home" CB_AX_APP="$ROOT_AX_APP" \
      CB_TEST_ADMIN_USER="$ACCOUNT" CB_TEST_CREDENTIAL_FIFO="$credential_fifo" \
      CB_EXPECTED_PROFILE_MARKER='DisablePrivateBrowsing = 1;' \
      "$REPO/tools/test-accessibility-profile-install.sh" --repair-only "$PRODUCTION_PROFILE"
  else
    /bin/launchctl asuser "$console_uid" /usr/bin/sudo -u "$console_user" \
      /usr/bin/env HOME="$console_home" CB_AX_APP="$ROOT_AX_APP" \
      CB_TEST_ADMIN_USER="$ACCOUNT" \
      CB_TEST_CREDENTIAL_FIFO="$credential_fifo" CB_TEST_GUARD_REMOVAL=1 \
      "$REPO/tools/test-accessibility-profile-install.sh"
  fi
  status=$?
  set -e
  /bin/kill -KILL "$writer" >/dev/null 2>&1 || true
  wait "$writer" 2>/dev/null || true
  writer=
  (( status == 0 )) || die "guarded profile install/update test failed"

  if (( RUN_VIRTUALBOX == 1 )); then
    install_virtualbox
  fi
  if (( PRODUCTION_REMOVE_ONLY == 1 )); then
    printf '%s\n' \
      "temporary_admin=created and authenticated" \
      "production_policy=removed for verifier repair test"
  elif (( PRODUCTION_REPAIR == 1 )); then
    printf '%s\n' \
      "temporary_admin=created and authenticated" \
      "production_policy=removed and reinstalled with temporary administrator"
  else
    printf '%s\n' \
      "temporary_admin=created and authenticated" \
      "policy_lifecycle=installed and updated with temporary administrator" \
      "removal_guard=verified during policy transaction"
  fi
}

console_delete_account() {
  local deadline
  account_exists || return 0
  [[ -f $MARKER ]] || die "refusing to remove unmarked account: $ACCOUNT"
  /usr/sbin/sysadminctl -secureTokenStatus "$ACCOUNT" 2>&1 | \
    /usr/bin/grep -Fq 'Secure token is ENABLED' && \
    die "refusing deletion of secure-token account: $ACCOUNT"
  /usr/sbin/dseditgroup -o edit -d "$ACCOUNT" -t user \
    -u "$SVC_ADMIN_USER" -P "$svc_credential" admin >/dev/null 2>&1 || true
  /usr/bin/dscl -u "$SVC_ADMIN_USER" -P "$svc_credential" . \
    -delete "/Users/$ACCOUNT" >/dev/null 2>&1 || true
  deadline=$(( $(/bin/date +%s) + 10 ))
  while account_exists && (( $(/bin/date +%s) < deadline )); do
    /bin/sleep 1
  done
  account_exists && die "temporary account remains after authenticated deletion: $ACCOUNT"
  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'do shell script (item 1 of argv) with administrator privileges' \
    -e 'end run' \
    "/bin/rm -rf /Users/$ACCOUNT $MARKER" >/dev/null
}

console_test() {
  local command output source_vbox status staged_vbox=
  svc_credential=$(/usr/bin/osascript -e \
    "text returned of (display dialog \"Enter the $SVC_ADMIN_USER credential. It is retained only by this coordinator to delete the tokenless temporary administrator after the root transaction exits.\" default answer \"\" with hidden answer buttons {\"Cancel\", \"Continue\"} default button \"Continue\" with title \"Temporary administrator policy test\")")
  [[ -n $svc_credential ]] || die "empty $SVC_ADMIN_USER credential"
  /usr/bin/dscl . -authonly "$SVC_ADMIN_USER" "$svc_credential" || \
    die "credential was rejected for $SVC_ADMIN_USER"
  console_delete_account

  if (( RUN_VIRTUALBOX == 1 )); then
    source_vbox=$VBOX_DMG
    [[ -n $source_vbox ]] || source_vbox=$HOME/Downloads/$VBOX_FILENAME
    [[ -f $source_vbox ]] || die "VirtualBox image not found: $source_vbox"
    staged_vbox=/Users/Shared/ChickenBlocker-VirtualBox-test.dmg
    /bin/rm -f "$staged_vbox"
    /bin/cp "$source_vbox" "$staged_vbox"
    /bin/chmod 0644 "$staged_vbox"
    VBOX_DMG=$staged_vbox
  fi

  printf -v command 'CB_TEST_DEFER_DELETE=1 CB_TEST_ACCOUNT_ONLY=%q %q' \
    "$ACCOUNT_ONLY" "$SELF"
  if (( PRODUCTION_REPAIR == 1 )); then
    printf -v command '%s --production-repair' "$command"
  fi
  if (( PRODUCTION_REMOVE_ONLY == 1 )); then
    printf -v command '%s --production-remove-only' "$command"
  fi
  if (( RUN_VIRTUALBOX == 1 )); then
    if [[ -n $VBOX_DMG ]]; then
      printf -v command '%s --virtualbox %q' "$command" "$VBOX_DMG"
    else
      printf -v command '%s --virtualbox' "$command"
    fi
  fi
  printf -v command '%s --root' "$command"
  set +e
  output=$(/usr/bin/osascript \
    -e 'on run argv' \
    -e 'do shell script (item 1 of argv) with administrator privileges' \
    -e 'end run' "$command" 2>&1)
  status=$?
  set -e
  [[ -z $output ]] || printf '%s\n' "$output"
  console_delete_account
  [[ -z $staged_vbox ]] || /bin/rm -f "$staged_vbox"
  unset svc_credential
  return "$status"
}

while (( $# > 0 )); do
  case $1 in
    --root)
      shift
      root_test
      exit
      ;;
    --virtualbox)
      RUN_VIRTUALBOX=1
      if [[ -n ${2:-} && ${2:-} != --* ]]; then
        VBOX_DMG=$2
        shift
      fi
      ;;
    --production-repair)
      PRODUCTION_REPAIR=1
      ;;
    --production-remove-only)
      PRODUCTION_REMOVE_ONLY=1
      ;;
    *)
      die "usage: $SELF [--production-repair|--production-remove-only|--virtualbox [path-to.dmg]]"
      ;;
  esac
  shift
done

if [[ $EUID -eq 0 ]]; then
  root_test
else
  console_test
fi
