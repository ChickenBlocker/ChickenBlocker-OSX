#!/bin/bash
# Gate the Accessibility-grant mechanism while the temporary administrator
# (svc-admin) still exists. Proves: the grant works in the console user's
# session, an ad-hoc rebuild loses it, and a stable self-signed code-signing
# identity keeps it across rebuilds. --verify re-checks later without admin.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
SOURCE="$REPO/agent/cb-ax-probe.swift"
PLIST_SRC="$REPO/agent/cb-ax-probe-Info.plist"
KEEPER="$HOME/Applications/ChickenBlocker AX Probe.app"
ROOT_KEEPER="/Library/Application Support/ChickenBlocker/agent/ChickenBlocker AX Probe.app"
RESULT=$(mktemp "${TMPDIR:-/tmp}/cb-ax-probe.XXXXXX")
GRANT_TIMEOUT=240
PANE='x-apple.systempreferences:com.apple.Settings.extension?Privacy_Accessibility'

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -f "$RESULT"
}
trap cleanup EXIT

preflight() {
  [[ $(/usr/bin/uname -s) == Darwin ]] || die "macOS only"
  [[ $EUID -ne 0 ]] || die "run as the console user, not root"
  local console_user
  console_user=$(/usr/bin/stat -f %Su /dev/console)
  [[ $console_user == $(/usr/bin/id -un) ]] || \
    die "this test must be run by the GUI console user ($console_user)"
}

require_tools() {
  /usr/bin/xcrun --find swiftc >/dev/null 2>&1 || \
    die "Xcode Command Line Tools required"
}

build_app() {
  local signer=$1
  /bin/rm -rf "$KEEPER.new"
  /bin/mkdir -p "$KEEPER.new/Contents/MacOS" "$HOME/Applications"
  /usr/bin/xcrun swiftc "$SOURCE" -o "$KEEPER.new/Contents/MacOS/cb-ax-probe"
  /bin/cp "$PLIST_SRC" "$KEEPER.new/Contents/Info.plist"
  /usr/bin/codesign --force --sign "$signer" "$KEEPER.new" >/dev/null 2>&1 || \
    die "codesign failed (signer: $signer)"
  /bin/rm -rf "$KEEPER"
  /bin/mv "$KEEPER.new" "$KEEPER"
}

probe() {
  local text
  /bin/rm -f "$RESULT"
  /usr/bin/open -W "$KEEPER" --args "$RESULT" >/dev/null 2>&1 || true
  text=$(/bin/cat "$RESULT" 2>/dev/null) || text=""
  if [[ $text == ok\ * ]]; then
    printf '%s\n' "$text"
    return 0
  fi
  printf '%s\n' "${text:-probe produced no result}" >&2
  return 1
}

show_dialog() {
  local message=$1 title=$2
  /usr/bin/osascript -e \
    "display dialog \"$message\" buttons {\"Continue\"} default button \"Continue\" giving up after 60 with title \"$title\"" \
    >/dev/null 2>&1 || true
}

wait_for_grant() {
  local label=$1 next_prompt=0
  local deadline=$(( $(/bin/date +%s) + GRANT_TIMEOUT ))
  while (( $(/bin/date +%s) < deadline )); do
    if probe >/dev/null 2>&1; then
      return 0
    fi
    if (( $(/bin/date +%s) >= next_prompt )); then
      /usr/bin/open "$PANE" >/dev/null 2>&1 || true
      /usr/bin/open -R "$KEEPER" >/dev/null 2>&1 || true
      show_dialog "In System Settings > Privacy & Security > Device Control and Data Access (the pane formerly called Accessibility), allow 'ChickenBlocker AX Probe' to control the computer: click +, press Cmd+Shift+G, paste the path revealed in Finder, then authenticate with the temporary administrator." "$label"
      next_prompt=$(( $(/bin/date +%s) + 30 ))
    fi
    /bin/sleep 2
  done
  return 1
}

codesigning_identity() {
  /usr/bin/security find-identity -p codesigning 2>/dev/null | \
    /usr/bin/sed -n 's/^[[:space:]]*[0-9]*)[[:space:]]*[A-Fa-f0-9]*[[:space:]]*"\(.*\)".*$/\1/p' | \
    /usr/bin/head -1
}

full_test() {
  local identity
  preflight
  require_tools

  printf '%s\n' "Phase A: ad-hoc build, grant once with the temporary administrator."
  build_app -
  wait_for_grant "Accessibility gate: step 1 of 2" || \
    die "grant was not added before timeout"
  probe >/dev/null

  printf '%s\n' "Phase B: identical rebuild, ad-hoc signature."
  build_app -
  if probe >/dev/null 2>&1; then
    printf '%s\n' "WARNING: grant survived an ad-hoc rebuild (unexpected on current macOS)."
  else
    printf '%s\n' "ad-hoc rebuild lost the grant, as expected."
  fi

  printf '%s\n' "Phase C: rebuild with a stable code-signing identity."
  identity=$(codesigning_identity)
  if [[ -z $identity ]]; then
    printf '%s\n' \
      "no code-signing identity found. Create one and re-run:" \
      "Keychain Access > Certificate Assistant > Create Certificate:" \
      "name: ChickenBlocker Code Signing, Identity Type: Self Signed Root," \
      "Certificate Type: Code Signing. Keep the key." >&2
    die "the probe currently has no working grant; the gate is not settled"
  fi
  printf '%s\n' "using identity: $identity"
  build_app "$identity"
  wait_for_grant "Accessibility gate: step 2 of 2 (stable identity)" || \
    die "grant was not added before timeout"
  probe >/dev/null

  build_app "$identity"
  probe >/dev/null || \
    die "grant did not survive a rebuild with the stable identity"

  printf '\nAccessibility gate:\n'
  printf 'stable_identity=%s\n' "$identity"
  printf 'keeper=%s\n' "$KEEPER"
  printf 'result=grant works and survives rebuilds\n'
  printf 'note=svc-admin can be removed only after this gate passes\n'
}

verify_only() {
  preflight
  [[ -d $KEEPER ]] || die "probe app is missing: $KEEPER"
  probe >/dev/null || \
    die "Accessibility grant is not working (signature changed or grant removed); repairing it needs a local administrator"
  printf '%s\n' "verified: Accessibility grant works without any administrator."
}

install_root() {
  local command identity ownership
  preflight
  require_tools
  identity=$(codesigning_identity)
  [[ -n $identity ]] || die "no stable code-signing identity"

  build_app "$identity"
  /usr/bin/codesign --verify --deep --strict "$KEEPER" >/dev/null 2>&1 || \
    die "staged probe signature verification failed"
  printf -v command \
    '/bin/mkdir -p %q && /bin/rm -rf %q.new && /usr/bin/ditto %q %q.new && /usr/sbin/chown -R root:wheel %q.new && /bin/chmod -R go-w %q.new && /bin/rm -rf %q && /bin/mv %q.new %q' \
    "$(dirname "$ROOT_KEEPER")" "$ROOT_KEEPER" "$KEEPER" "$ROOT_KEEPER" \
    "$ROOT_KEEPER" "$ROOT_KEEPER" "$ROOT_KEEPER" "$ROOT_KEEPER" "$ROOT_KEEPER"
  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'do shell script (item 1 of argv) with administrator privileges' \
    -e 'end run' "$command" >/dev/null

  ownership=$(/usr/bin/stat -f '%Su:%Sg' "$ROOT_KEEPER")
  [[ $ownership == root:wheel ]] || die "root probe has unexpected ownership: $ownership"
  [[ ! -w $ROOT_KEEPER && ! -w $ROOT_KEEPER/Contents/MacOS/cb-ax-probe ]] || \
    die "root probe remains writable by the console user"
  /usr/bin/codesign --verify --deep --strict "$ROOT_KEEPER" >/dev/null 2>&1 || \
    die "root probe signature verification failed"

  KEEPER=$ROOT_KEEPER
  wait_for_grant "Accessibility gate: root-owned helper" || \
    die "Accessibility grant was not added for the root-owned helper"
  probe >/dev/null
  printf '%s\n' \
    "root_keeper=$ROOT_KEEPER" \
    "ownership=$ownership" \
    "result=root-owned helper is protected and its Accessibility grant works"
}

verify_root() {
  KEEPER=$ROOT_KEEPER
  verify_only
  ownership=$(/usr/bin/stat -f '%Su:%Sg' "$KEEPER")
  [[ $ownership == root:wheel ]] || die "root probe has unexpected ownership: $ownership"
  [[ ! -w $KEEPER && ! -w $KEEPER/Contents/MacOS/cb-ax-probe ]] || \
    die "root probe is writable by the console user"
  printf '%s\n' "verified: root-owned Accessibility helper is protected."
}

case ${1:-} in
  --verify)
    verify_only
    ;;
  --install-root)
    install_root
    ;;
  --verify-root)
    verify_root
    ;;
  '')
    full_test
    ;;
  *)
    die "usage: $0 [--verify|--install-root|--verify-root]"
    ;;
esac
