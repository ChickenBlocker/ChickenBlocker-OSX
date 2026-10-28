#!/bin/bash
# Prove that the granted helper can install and update a disposable profile.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
APP="$HOME/Applications/ChickenBlocker AX Probe.app"
SOURCE="$REPO/agent/cb-ax-probe.swift"
PLIST_SRC="$REPO/agent/cb-ax-probe-Info.plist"
CLEANUP_ONLY=0
if [[ ${1:-} == --cleanup-only ]]; then
  CLEANUP_ONLY=1
  shift
fi
PROFILE_V1=${1:-$REPO/tests/fixtures/accessibility-profile-v1.mobileconfig}
PROFILE_V2=${2:-$REPO/tests/fixtures/accessibility-profile-v2.mobileconfig}
ADMIN_USER=${CB_TEST_ADMIN_USER:-svc-admin}
PANE='x-apple.systempreferences:com.apple.Profiles-Settings.extension'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cb-ax-profile.XXXXXX")
RESULT="$TMP/result"
LOG="$TMP/install.log"
FIFO="$TMP/credential"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local rc=${1:-0}
  unset credential
  [[ -z ${writer:-} ]] || kill "$writer" >/dev/null 2>&1 || true
  if (( rc == 0 )); then
    rm -rf "$TMP"
  else
    [[ ! -s $LOG ]] || /bin/cat "$LOG" >&2
    printf 'diagnostics=%s\n' "$TMP" >&2
  fi
}
trap 'cleanup $?' EXIT
trap 'exit 130' INT TERM

profile_dump() {
  /usr/sbin/system_profiler SPConfigurationProfileDataType -json 2>/dev/null
}

profile_present() {
  profile_dump | /usr/bin/grep -Fq "$PROFILE_ID"
}

profile_has_uuid() {
  profile_dump | /usr/bin/grep -Fq "$1"
}

profile_has_marker() {
  profile_dump | /usr/bin/grep -Fq "TestVersion = $1;"
}

build_app() {
  local identity
  identity=$(/usr/bin/security find-identity -p codesigning 2>/dev/null | \
    /usr/bin/sed -n 's/^[[:space:]]*[0-9]*)[[:space:]]*[A-Fa-f0-9]*[[:space:]]*"\(.*\)".*$/\1/p' | \
    /usr/bin/head -1)
  [[ -n $identity ]] || die "no stable code-signing identity"
  /bin/rm -rf "$APP.new"
  /bin/mkdir -p "$APP.new/Contents/MacOS"
  /usr/bin/xcrun swiftc "$SOURCE" -o "$APP.new/Contents/MacOS/cb-ax-probe"
  /bin/cp "$PLIST_SRC" "$APP.new/Contents/Info.plist"
  /usr/bin/codesign --force --sign "$identity" "$APP.new" >/dev/null 2>&1 || \
    die "codesign failed"
  /bin/rm -rf "$APP"
  /bin/mv "$APP.new" "$APP"
}

restart_settings() {
  local deadline
  /usr/bin/pkill -TERM -x "System Settings" >/dev/null 2>&1 || true
  /usr/bin/pkill -TERM -x SecurityAgent >/dev/null 2>&1 || true
  deadline=$(( $(/bin/date +%s) + 10 ))
  while /usr/bin/pgrep -x "System Settings" >/dev/null 2>&1 && \
      (( $(/bin/date +%s) < deadline )); do
    /bin/sleep 1
  done
  /usr/bin/pgrep -x "System Settings" >/dev/null 2>&1 && \
    die "System Settings did not terminate"
  /usr/bin/open "$PANE"
  /bin/sleep 3
}

remove_installed_profile() {
  local deadline
  /bin/rm -f "$RESULT" "$LOG" "$FIFO"
  : > "$LOG"
  /usr/bin/open "$APP" --args --start-profile-removal "$RESULT" "$LOG" \
    "$PROFILE_NAME" "$PROFILE_ID"
  deadline=$(( $(/bin/date +%s) + 30 ))
  while [[ ! -s $RESULT ]] && (( $(/bin/date +%s) < deadline )); do
    /bin/sleep 1
  done
  [[ -s $RESULT ]] || die "helper did not start disposable profile removal"
  /bin/cat "$RESULT"
  /usr/bin/grep -Fq 'removal_started=1' "$RESULT" || \
    die "helper could not start disposable profile removal"

  deadline=$(( $(/bin/date +%s) + 5 ))
  while profile_present && (( $(/bin/date +%s) < deadline )); do
    /bin/sleep 1
  done
  if profile_present; then
    /bin/rm -f "$RESULT" "$FIFO"
    /usr/bin/mkfifo -m 0600 "$FIFO"
    /usr/bin/open "$APP" --args --inject-auth "$FIFO" "$RESULT" \
      "$ADMIN_USER" "$LOG" "$PROFILE_NAME"
    (printf '%s\n' "$credential" > "$FIFO") 2>/dev/null &
    writer=$!
    deadline=$(( $(/bin/date +%s) + 40 ))
    while [[ ! -s $RESULT ]] && (( $(/bin/date +%s) < deadline )); do
      /bin/sleep 1
    done
    [[ -s $RESULT ]] || die "credential helper produced no removal result"
    kill "$writer" >/dev/null 2>&1 || true
    wait "$writer" 2>/dev/null || true
    writer=
    /bin/cat "$RESULT"
  fi
  deadline=$(( $(/bin/date +%s) + 30 ))
  while profile_present && (( $(/bin/date +%s) < deadline )); do
    /bin/sleep 2
  done
  profile_present && die "disposable installed profile could not be removed"
  /bin/cat "$LOG"
  printf '%s\n' "pretest_cleanup=installed disposable profile removed"
}

run_transaction() {
  local profile=$1 label=$2 expected_uuid=$3 expected_marker=$4 deadline profile_ready=0
  /bin/rm -f "$RESULT" "$FIFO"
  /usr/bin/mkfifo -m 0600 "$FIFO"
  : > "$LOG"
  /usr/bin/open "$APP" --args --install-profile "$profile" "$FIFO" "$RESULT" \
    "$ADMIN_USER" "$LOG" "$PROFILE_NAME" "$PROFILE_ID" "$label" "$expected_uuid" "$expected_marker"
  (printf '%s\n' "$credential" > "$FIFO") 2>/dev/null &
  writer=$!

  deadline=$(( $(/bin/date +%s) + 130 ))
  while [[ ! -s $RESULT ]] && (( $(/bin/date +%s) < deadline )); do
    if profile_has_uuid "$expected_uuid" && profile_has_marker "$expected_marker"; then
      profile_ready=1
      break
    fi
    /bin/sleep 1
  done
  if (( profile_ready == 1 )) && [[ ! -s $RESULT ]]; then
    /usr/bin/pkill -TERM -x cb-ax-probe >/dev/null 2>&1 || true
    printf 'submitted=1 authorization=not-shown-or-cached external_verification=1\n' > "$RESULT"
  fi
  [[ -s $RESULT ]] || die "helper produced no result for $label"
  kill "$writer" >/dev/null 2>&1 || true
  wait "$writer" 2>/dev/null || true
  writer=
  /bin/cat "$RESULT"
  /bin/cat "$LOG"

  deadline=$(( $(/bin/date +%s) + 30 ))
  while { ! profile_has_uuid "$expected_uuid" || ! profile_has_marker "$expected_marker"; } && \
      (( $(/bin/date +%s) < deadline )); do
    /bin/sleep 2
  done
  profile_has_uuid "$expected_uuid" && profile_has_marker "$expected_marker" || \
    die "$label did not install expected UUID/marker $expected_uuid/$expected_marker"
  printf 'profile_transaction=%s uuid=%s marker=%s verified=1\n' \
    "$label" "$expected_uuid" "$expected_marker"
}

[[ $(/usr/bin/uname -s) == Darwin ]] || die "macOS only"
[[ $EUID -ne 0 ]] || die "run as the GUI console user, not root"
[[ $# -le 2 ]] || die "usage: $0 [--cleanup-only] [initial.mobileconfig] [updated.mobileconfig]"
[[ -f $PROFILE_V1 && -f $PROFILE_V2 ]] || die "both mobileconfig files must exist"
/usr/bin/plutil -lint "$PROFILE_V1" "$PROFILE_V2" >/dev/null
PROFILE_ID=$(/usr/libexec/PlistBuddy -c 'Print :PayloadIdentifier' "$PROFILE_V1")
PROFILE_NAME=$(/usr/libexec/PlistBuddy -c 'Print :PayloadDisplayName' "$PROFILE_V1")
PROFILE_UUID_V1=$(/usr/libexec/PlistBuddy -c 'Print :PayloadUUID' "$PROFILE_V1")
PROFILE_UUID_V2=$(/usr/libexec/PlistBuddy -c 'Print :PayloadUUID' "$PROFILE_V2")
PROFILE_VERSION_V1=$(/usr/libexec/PlistBuddy -c 'Print :PayloadVersion' "$PROFILE_V1")
PROFILE_VERSION_V2=$(/usr/libexec/PlistBuddy -c 'Print :PayloadVersion' "$PROFILE_V2")
PROFILE_MARKER_V1=$(/usr/libexec/PlistBuddy -c \
  "Print :PayloadContent:0:PayloadContent:$PROFILE_ID:Forced:0:mcx_preference_settings:TestVersion" "$PROFILE_V1")
PROFILE_MARKER_V2=$(/usr/libexec/PlistBuddy -c \
  "Print :PayloadContent:0:PayloadContent:$PROFILE_ID:Forced:0:mcx_preference_settings:TestVersion" "$PROFILE_V2")
[[ $PROFILE_ID == $(/usr/libexec/PlistBuddy -c 'Print :PayloadIdentifier' "$PROFILE_V2") ]] || \
  die "update profile must use the same PayloadIdentifier"
[[ $PROFILE_NAME == $(/usr/libexec/PlistBuddy -c 'Print :PayloadDisplayName' "$PROFILE_V2") ]] || \
  die "update profile must use the same PayloadDisplayName"
[[ $PROFILE_UUID_V1 == "$PROFILE_UUID_V2" ]] || die "update profile must retain the same PayloadUUID"
(( PROFILE_VERSION_V2 > PROFILE_VERSION_V1 )) || die "update PayloadVersion must increase"
[[ -d $APP ]] || die "helper app missing; run tools/test-accessibility-grant.sh first"
"$REPO/tools/test-accessibility-grant.sh" --verify >/dev/null
build_app
"$REPO/tools/test-accessibility-grant.sh" --verify >/dev/null
resume_v1=0
cleanup_installed=0
if profile_present; then
  if (( CLEANUP_ONLY == 0 )) && [[ ${CB_RESUME_INSTALLED_V1:-0} == 1 ]] && \
      profile_has_uuid "$PROFILE_UUID_V1" && profile_has_marker "$PROFILE_MARKER_V1"; then
    resume_v1=1
    printf '%s\n' "resume=installed v1 verified; testing update only"
  else
    cleanup_installed=1
  fi
fi
if (( CLEANUP_ONLY == 1 && cleanup_installed == 0 )); then
  printf '%s\n' "cleanup=disposable profile already absent"
  exit 0
fi

credential=$(/usr/bin/osascript -e \
  "text returned of (display dialog \"Enter the $ADMIN_USER credential. System Settings may reuse a previous successful authorization and show no password prompt; that is expected.\" default answer \"\" with hidden answer buttons {\"Cancel\", \"Continue\"} default button \"Continue\" with title \"Accessibility profile install/update test\")")
[[ -n $credential ]] || die "empty credential"
/usr/bin/dscl . -authonly "$ADMIN_USER" "$credential" || \
  die "credential was rejected for $ADMIN_USER; no UI input attempted"

if (( cleanup_installed == 1 )); then
  restart_settings
  remove_installed_profile
fi
if (( CLEANUP_ONLY == 1 )); then
  printf '%s\n' "cleanup=disposable profile removed and verified absent"
  exit 0
fi
restart_settings
if (( resume_v1 == 0 )); then
  run_transaction "$PROFILE_V1" install "$PROFILE_UUID_V1" "$PROFILE_MARKER_V1"
fi
run_transaction "$PROFILE_V2" update "$PROFILE_UUID_V2" "$PROFILE_MARKER_V2"
unset credential

printf '%s\n' \
  "lifecycle=absent -> profile installed -> same identifier updated" \
  "result=accessibility profile add and update succeeded" \
  "note=authorization may be absent when System Settings remembers a previous successful password"
