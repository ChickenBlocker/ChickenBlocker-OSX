#!/bin/bash
# Dump the accessibility tree of System Settings while a profile detail
# window is open, to see what identifies the policy view. Read-only.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
SOURCE="$REPO/agent/cb-ax-probe.swift"
PLIST_SRC="$REPO/agent/cb-ax-probe-Info.plist"
KEEPER="$HOME/Applications/ChickenBlocker AX Probe.app"
DUMP=$(mktemp "${TMPDIR:-/tmp}/cb-policy-dump.XXXXXX")

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -f "$DUMP"
}
trap cleanup EXIT

codesigning_identity() {
  /usr/bin/security find-identity -p codesigning 2>/dev/null | \
    /usr/bin/sed -n 's/^[[:space:]]*[0-9]*)[[:space:]]*[A-Fa-f0-9]*[[:space:]]*"\(.*\)".*$/\1/p' | \
    /usr/bin/head -1
}

[[ $(/usr/bin/uname -s) == Darwin ]] || die "macOS only"
[[ $EUID -ne 0 ]] || die "run as the console user, not root"
[[ -d $KEEPER ]] || die "keeper app missing; run tools/test-accessibility-grant.sh first"
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

/usr/bin/osascript -e \
  "display dialog \"In System Settings, open General > Device Management with the profile list visible (no detail sheet open), so the + and - buttons are shown, then click Continue.\" buttons {\"Continue\"} default button \"Continue\" giving up after 180 with title \"Device Management dump\"" \
  >/dev/null 2>&1 || true

/bin/rm -f "$DUMP"
/usr/bin/open -W "$KEEPER" --args --dump "$DUMP" >/dev/null 2>&1 || true
[[ -s $DUMP ]] || die "dump produced no output"
/usr/bin/grep -E "AXSheet|AXDialog|AXWindow|Install|Remove|profile|Profile|ChickenBlocker|Firefox|mozilla" "$DUMP" || true
printf '\n--- full dump (%s lines) ---\n' "$(/usr/bin/wc -l < "$DUMP" | /usr/bin/tr -d ' ')"
/bin/cat "$DUMP"
