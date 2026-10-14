#!/bin/bash
# ChickenBlocker-OSX install — Firefox policy + LeechBlock rule verifier.
#
# Usage:
#   sudo ./install.sh              install on this Mac
#   ./install.sh user@mac-host     push this checkout to the Mac over SSH and
#                                  install it there (SSH is used ONLY when a
#                                  target is given)
#
# What it installs (all root:wheel):
#   /Library/Application Support/ChickenBlocker/verifier.sh          (0755)
#   /Library/Application Support/ChickenBlocker/verifier.conf        (0644, kept if edited)
#   /Library/Application Support/ChickenBlocker/expected/firefox-policies.json
#   /Library/LaunchDaemons/com.chickenblocker.verifier.plist
#
# LeechBlock/keyword rules are NOT part of this step: they are pushed from
# the Linux ChickenBlocker machine with sync/sync-to-mac.sh afterwards.
set -eu

LABEL="com.chickenblocker.verifier"
BASE="/Library/Application Support/ChickenBlocker"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
REPO="$(cd "$(dirname "$0")" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

install_local() {
  [ "$(uname -s)" = Darwin ] || die "not macOS (run on the Mac, or pass user@mac-host)"
  if [ "$(id -u)" != 0 ]; then
    exec sudo bash "$REPO/install.sh" --local
  fi

  echo ">> Installing verifier into $BASE"
  install -d -o root -g wheel -m 0755 \
    "$BASE" "$BASE/expected" "$BASE/expected/extensions" "$BASE/extensions"
  install -m 0755 -o root -g wheel "$REPO/daemon/cb-verifier.sh" "$BASE/verifier.sh"
  if [ ! -f "$BASE/verifier.conf" ]; then
    printf 'CHECK_INTERVAL=15\nRESTART_FIREFOX_ON_REPAIR=1\nEXT_RESTART_MIN_INTERVAL=300\n' > "$BASE/verifier.conf"
    chown root:wheel "$BASE/verifier.conf"
    chmod 0644 "$BASE/verifier.conf"
    echo ">> Wrote default $BASE/verifier.conf (preserved on reinstall)"
  fi
  install -m 0644 -o root -g wheel \
    "$REPO/config/firefox-policies.json" "$BASE/expected/firefox-policies.json"

  echo ">> Generating + installing Firefox configuration profile"
  command -v python3 >/dev/null 2>&1 || \
    die "python3 is required on the Mac (install Xcode Command Line Tools)"
  python3 "$REPO/tools/gen-firefox-profile.py" \
    "$REPO/config/firefox-policies.json" \
    "$BASE/expected/org.mozilla.firefox.mobileconfig"
  chmod 0644 "$BASE/expected/org.mozilla.firefox.mobileconfig"
  chown root:wheel "$BASE/expected/org.mozilla.firefox.mobileconfig"
  profiles install -path "$BASE/expected/org.mozilla.firefox.mobileconfig" || \
    die "profiles install failed"

  echo ">> Removing legacy in-bundle policies.json (TCC-blocked channel)"
  for app in /Applications/Firefox.app /Users/*/Applications/Firefox.app; do
    [ -d "$app" ] || continue
    rm -f "$app/Contents/Resources/distribution/policies.json"
    rmdir "$app/Contents/Resources/distribution" 2>/dev/null || true
  done

  echo ">> Installing LaunchDaemon $PLIST"
  install -m 0644 -o root -g wheel "$REPO/daemon/$LABEL.plist" "$PLIST"

  echo ">> Loading daemon"
  launchctl bootout "system/$LABEL" 2>/dev/null || true
  # Wait until the label is really gone (bootout is asynchronous; the old
  # job's processes may still be dying), then bootstrap with retries.
  i=0
  while [ "$i" -lt 10 ] && launchctl print "system/$LABEL" >/dev/null 2>&1; do
    sleep 1
    i=$((i+1))
  done
  loaded=""
  for attempt in 1 2 3; do
    if launchctl bootstrap system "$PLIST" 2>/dev/null; then
      loaded=1
      break
    fi
    sleep 2
  done
  if [ -z "$loaded" ]; then
    launchctl load -w "$PLIST" 2>/dev/null || true
  fi
  sleep 1
  launchctl print "system/$LABEL" >/dev/null 2>&1 || \
    die "LaunchDaemon did not load (bootstrap EIO); check: sudo launchctl print system/$LABEL"

  echo ">> Initial audit"
  bash "$BASE/verifier.sh" check || true

  echo
  echo "Done. Firefox policies are enforced;"
  echo "LeechBlock + keyword rules must still be pushed from the Linux machine:"
  echo "  ChickenBlocker-OSX/sync/sync-to-mac.sh user@mac-host"
}

case "${1:-}" in
  --local)
    install_local
    ;;
  -h|--help|help)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  "")
    install_local
    ;;
  *)
    TARGET="$1"
    echo ">> Remote install to $TARGET over SSH"
    ssh -o BatchMode=yes "$TARGET" true || die "cannot reach $TARGET over SSH (key-based login required)"
    [ "$(ssh -o BatchMode=yes "$TARGET" 'uname -s')" = Darwin ] || die "$TARGET is not a Mac"
    RT="/tmp/chickenblocker-osx-install"
    echo ">> Copying files"
    tar -cf - -C "$REPO" README.md install.sh uninstall.sh config daemon tools | \
      ssh "$TARGET" "rm -rf '$RT' && mkdir -p '$RT' && tar -C '$RT' -xf -"
    echo ">> Installing on $TARGET (sudo password may be asked)"
    ssh -t "$TARGET" "sudo bash '$RT/install.sh' --local; rc=\$?; rm -rf '$RT'; exit \$rc"
    ;;
esac
