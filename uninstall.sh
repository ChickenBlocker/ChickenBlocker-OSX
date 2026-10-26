#!/bin/bash
# ChickenBlocker-OSX uninstall — stop the verifier and remove every deployed
# file (daemon, break overlay, expected files, policies, managed manifests).
#
# Usage:
#   sudo ./uninstall.sh              uninstall on this Mac
#   ./uninstall.sh user@mac-host     uninstall remotely over SSH (SSH is used
#                                    ONLY when a target is given)
set -eu

LABEL="com.chickenblocker.verifier"
BREAK_LABEL="com.chickenblocker.breaks"
BASE="/Library/Application Support/ChickenBlocker"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
BREAK_PLIST="/Library/LaunchAgents/$BREAK_LABEL.plist"
MS_DIR="/Library/Application Support/Mozilla/ManagedStorage"
REPO="$(cd "$(dirname "$0")" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

uninstall_local() {
  [ "$(uname -s)" = Darwin ] || die "not macOS"
  if [ "$(id -u)" != 0 ]; then
    exec sudo bash "$REPO/uninstall.sh" --local
  fi

  echo ">> Stopping daemon"
  launchctl bootout "system/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"

  echo ">> Stopping break overlay"
  console_uid="$(stat -f %u /dev/console 2>/dev/null || true)"
  if [ -n "$console_uid" ] && [ "$console_uid" != 0 ]; then
    launchctl bootout "gui/$console_uid/$BREAK_LABEL" 2>/dev/null || true
  fi
  pkill -f "$BASE/agent/cb-break-overlay" 2>/dev/null || true
  rm -f "$BREAK_PLIST"

  echo ">> Removing Firefox managed preferences"
  rm -f "/Library/Managed Preferences/org.mozilla.firefox.plist"
  profiles remove -identifier com.chickenblocker.firefox 2>/dev/null || true

  echo ">> Removing any in-bundle policies.json"
  for app in /Applications/Firefox.app /Users/*/Applications/Firefox.app; do
    [ -d "$app" ] || continue
    rm -f "$app/Contents/Resources/distribution/policies.json"
    rmdir "$app/Contents/Resources/distribution" 2>/dev/null || true
  done

  echo ">> Removing managed-storage manifests"
  rm -f "$MS_DIR/leechblockng@proginosko.com.json" \
        "$MS_DIR/page-keyword-filter-7f3a@local.addons.json"
  rmdir "$MS_DIR" "/Library/Application Support/Mozilla" 2>/dev/null || true

  echo ">> Removing /usr/local/lib/ChickenBlocker"
  rm -rf "/usr/local/lib/ChickenBlocker"

  echo ">> Removing $BASE"
  rm -rf "$BASE"

  echo "Done. Restart Firefox to fully drop the managed policies and rules."
}

case "${1:-}" in
  --local)
    uninstall_local
    ;;
  -h|--help|help)
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  "")
    uninstall_local
    ;;
  *)
    TARGET="$1"
    echo ">> Remote uninstall on $TARGET over SSH"
    ssh -o BatchMode=yes "$TARGET" true || die "cannot reach $TARGET over SSH (key-based login required)"
    RT="/tmp/chickenblocker-osx-uninstall"
    tar -cf - -C "$REPO" uninstall.sh | \
      ssh "$TARGET" "rm -rf '$RT' && mkdir -p '$RT' && tar -C '$RT' -xf -"
    ssh -t "$TARGET" "sudo bash '$RT/uninstall.sh' --local; rc=\$?; rm -rf '$RT'; exit \$rc"
    ;;
esac
