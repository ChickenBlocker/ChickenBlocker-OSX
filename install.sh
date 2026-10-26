#!/bin/bash
# ChickenBlocker-OSX install — Firefox policy + LeechBlock rule verifier.
#
# Usage:
#   sudo ./install.sh              install on this Mac
#
# What it installs (all root:wheel):
#   /Library/Application Support/ChickenBlocker/verifier.sh          (0755)
#   /Library/Application Support/ChickenBlocker/verifier.conf        (0644, kept if edited)
#   /Library/Application Support/ChickenBlocker/expected/firefox-policies.json
#   /Library/LaunchDaemons/com.chickenblocker.verifier.plist
#   /Library/LaunchAgents/com.chickenblocker.breaks.plist
#   /Library/Application Support/ChickenBlocker/agent/ChickenBlocker Breaks.app
#
# LeechBlock/keyword rules are NOT part of this step: they are deployed through
# a separately reviewed signed release built by sync/sync-to-mac.sh.
set -eu

LABEL="com.chickenblocker.verifier"
BREAK_LABEL="com.chickenblocker.breaks"
BREAK_APP="ChickenBlocker Breaks.app"
BASE="/Library/Application Support/ChickenBlocker"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
BREAK_PLIST="/Library/LaunchAgents/$BREAK_LABEL.plist"
REPO="$(cd "$(dirname "$0")" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

install_local() {
  [ "$(uname -s)" = Darwin ] || die "not macOS (run on the Mac, or pass user@mac-host)"
  if [ "$(id -u)" != 0 ]; then
    exec sudo bash "$REPO/install.sh" --local
  fi

  echo ">> Installing verifier into $BASE"
  install -d -o root -g wheel -m 0755 \
    "$BASE" "$BASE/expected" "$BASE/expected/extensions" "$BASE/extensions" \
    "$BASE/agent"
  install -m 0755 -o root -g wheel "$REPO/daemon/cb-verifier.sh" "$BASE/verifier.sh"

  echo ">> Building private interpreter $BASE/bin/cb-bash (FDA is granted to THIS binary only)"
  install -d -o root -g wheel -m 0750 "$BASE/bin"
  if [ ! -x "$BASE/bin/cb-bash" ] || ! cmp -s /bin/bash "$BASE/bin/cb-bash"; then
    cp /bin/bash "$BASE/bin/cb-bash.new"
    codesign --force --sign - "$BASE/bin/cb-bash.new" >/dev/null 2>&1 || \
      die "codesign failed (Xcode Command Line Tools required)"
    chmod 0700 "$BASE/bin/cb-bash.new"
    chown root:wheel "$BASE/bin/cb-bash.new"
    mv "$BASE/bin/cb-bash.new" "$BASE/bin/cb-bash"
  fi
  chmod 0700 "$BASE/bin/cb-bash"

  echo ">> Building macOS break overlay"
  command -v xcrun >/dev/null 2>&1 || die "xcrun is required (install Xcode Command Line Tools)"
  rm -rf "$BASE/expected/$BREAK_APP"
  install -d -o root -g wheel -m 0755 \
    "$BASE/expected/$BREAK_APP/Contents/MacOS"
  xcrun swiftc -parse-as-library "$REPO/agent/cb-break-overlay.swift" \
    -o "$BASE/expected/$BREAK_APP/Contents/MacOS/cb-break-overlay"
  install -m 0644 -o root -g wheel "$REPO/agent/cb-break-overlay-Info.plist" \
    "$BASE/expected/$BREAK_APP/Contents/Info.plist"
  chown -R root:wheel "$BASE/expected/$BREAK_APP"
  codesign --force --deep --sign - "$BASE/expected/$BREAK_APP" >/dev/null 2>&1 || \
    die "codesign failed for break overlay app"
  rm -rf "$BASE/agent/$BREAK_APP"
  ditto "$BASE/expected/$BREAK_APP" "$BASE/agent/$BREAK_APP"
  chown -R root:wheel "$BASE/agent/$BREAK_APP"
  rm -f "$BASE/expected/cb-break-overlay" "$BASE/agent/cb-break-overlay"
  install -m 0700 -o root -g wheel "$REPO/tools/break-scheduler.py" \
    "$BASE/expected/break-scheduler.py"
  install -m 0700 -o root -g wheel "$BASE/expected/break-scheduler.py" \
    "$BASE/bin/break-scheduler.py"
  install -m 0644 -o root -g wheel "$REPO/config/breaks.json" \
    "$BASE/expected/breaks.json"
  install -m 0644 -o root -g wheel "$BASE/expected/breaks.json" "$BASE/breaks.json"
  install -m 0644 -o root -g wheel "$REPO/agent/$BREAK_LABEL.plist" \
    "$BASE/expected/$BREAK_LABEL.plist"
  install -m 0644 -o root -g wheel "$BASE/expected/$BREAK_LABEL.plist" "$BREAK_PLIST"
  if [ ! -f "$BASE/verifier.conf" ]; then
    printf 'CHECK_INTERVAL=15\nRESTART_FIREFOX_ON_REPAIR=1\nEXT_RESTART_MIN_INTERVAL=300\nSANTA_CHECKS=0\nSANTA_ENFORCE_SAFARI=0\nSANTA_LOCAL_RULE_FALLBACK=1\nSANTA_REINSTALL=0\n' > "$BASE/verifier.conf"
    chown root:wheel "$BASE/verifier.conf"
    chmod 0644 "$BASE/verifier.conf"
    echo ">> Wrote default $BASE/verifier.conf (preserved on reinstall)"
  else
    for setting in SANTA_CHECKS=0 SANTA_ENFORCE_SAFARI=0 SANTA_LOCAL_RULE_FALLBACK=1 SANTA_REINSTALL=0; do
      key="${setting%%=*}"
      grep -q "^$key=" "$BASE/verifier.conf" || printf '%s\n' "$setting" >> "$BASE/verifier.conf"
    done
  fi
  install -m 0644 -o root -g wheel \
    "$REPO/config/firefox-policies.json" "$BASE/expected/firefox-policies.json"

  echo ">> Generating Firefox policy delivery files"
  command -v python3 >/dev/null 2>&1 || \
    die "python3 is required on the Mac (install Xcode Command Line Tools)"
  python3 "$REPO/tools/gen-firefox-profile.py" \
    "$REPO/config/firefox-policies.json" "$BASE/expected/"
  chown root:wheel "$BASE/expected/org.mozilla.firefox.plist" \
                    "$BASE/expected/org.mozilla.firefox.mobileconfig"
  chmod 0644 "$BASE/expected/org.mozilla.firefox.plist" \
             "$BASE/expected/org.mozilla.firefox.mobileconfig"
  rm -f "/Library/Managed Preferences/org.mozilla.firefox.plist"

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

  console_uid="$(stat -f %u /dev/console 2>/dev/null || true)"
  console_user="$(stat -f %Su /dev/console 2>/dev/null || true)"
  if [ -n "$console_uid" ] && [ "$console_uid" != 0 ]; then
    launchctl bootout "gui/$console_uid/$BREAK_LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$console_uid" "$BREAK_PLIST" 2>/dev/null || true
    launchctl kickstart "gui/$console_uid/$BREAK_LABEL" 2>/dev/null || true
  fi

  echo ">> Initial audit"
  "$BASE/bin/cb-bash" "$BASE/verifier.sh" check || true

  echo
  profile_user="$console_user"
  profile_prefs="/Library/Managed Preferences/$profile_user/org.mozilla.firefox.plist"
  if [ -n "$profile_user" ] &&
     profiles show -type configuration -user "$profile_user" 2>/dev/null | grep -q "com.chickenblocker.firefox" &&
     [ "$(plutil -extract EnterprisePoliciesEnabled raw -o - "$profile_prefs" 2>/dev/null || true)" = true ] &&
     [ "$(plutil -extract DisablePrivateBrowsing raw -o - "$profile_prefs" 2>/dev/null || true)" = true ]; then
    echo "Firefox configuration profile: installed and active for $profile_user"
  else
    echo "[!] Firefox policies need approval in Device Management."
    if [ -n "$profile_user" ] && [ "$profile_user" != root ] &&
       [ -n "$console_uid" ] && [ "$console_uid" != 0 ]; then
      launchctl asuser "$console_uid" sudo -u "$profile_user" \
        open "$BASE/expected/org.mozilla.firefox.mobileconfig" >/dev/null 2>&1 || true
      sleep 2
      launchctl asuser "$console_uid" sudo -u "$profile_user" \
        open 'x-apple.systempreferences:com.apple.Profiles-Settings.extension' \
        >/dev/null 2>&1 || true
      echo "    Staged org.mozilla.firefox.mobileconfig and opened Device Management."
    else
      echo "    No GUI console user is available; stage this profile after login:"
      echo "    $BASE/expected/org.mozilla.firefox.mobileconfig"
    fi
    echo "    Select the Firefox profile, then choose Install (admin approval required)."
  fi
  fda="$(sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
    "SELECT auth_value FROM access WHERE service='kTCCServiceSystemPolicyAllFiles' AND client LIKE '%cb-bash';" 2>/dev/null || true)"
  if [ "$fda" = "2" ]; then
    echo "Full Disk Access for cb-bash: granted"
  else
    echo "[!] For extension-state enforcement, grant Full Disk Access to the verifier's"
    echo "    private interpreter (NOT /bin/bash):"
    echo "    System Settings -> Privacy & Security -> Full Disk Access -> +"
    echo "    Cmd+Shift+G -> /Library/Application Support/ChickenBlocker/bin/cb-bash -> Open"
    echo "    (ad-hoc signed copy; no other bash gets this grant)"
  fi
  echo
  echo "Done. Build rule updates as signed-release bundles with:"
  echo "  ChickenBlocker-OSX/sync/sync-to-mac.sh"
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
    die "remote install is disabled; stage a signed bundle with tools/stage-repository-release.sh"
esac
