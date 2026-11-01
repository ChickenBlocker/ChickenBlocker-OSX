#!/bin/bash
# Require explicit user action for every Apple and App Store update.
set -euo pipefail

SOFTWARE_UPDATE=/Library/Preferences/com.apple.SoftwareUpdate
COMMERCE=/Library/Preferences/com.apple.commerce

[[ $(/usr/bin/uname -s) == Darwin && $EUID -eq 0 ]] || {
  echo "ERROR: manual-update policy requires macOS root" >&2
  exit 1
}
[[ ${CB_RELEASE_SEQUENCE:-} =~ ^[1-9][0-9]*$ ]] || {
  echo "ERROR: invalid release sequence" >&2
  exit 1
}

/usr/sbin/softwareupdate --schedule off >/dev/null

for key in AutomaticCheckEnabled AutomaticDownload \
    AutomaticallyInstallMacOSUpdates AutomaticallyInstallAppUpdates \
    CriticalUpdateInstall ConfigDataInstall; do
  /usr/bin/defaults write "$SOFTWARE_UPDATE" "$key" -bool false
done
/usr/bin/defaults write "$COMMERCE" AutoUpdate -bool false
/usr/bin/defaults write "$COMMERCE" AutoUpdateRestartRequired -bool false

# Restart preference consumers so the policy is effective immediately.
/usr/bin/killall softwareupdated >/dev/null 2>&1 || true
/usr/bin/killall storedownloadd >/dev/null 2>&1 || true

for key in AutomaticCheckEnabled AutomaticDownload \
    AutomaticallyInstallMacOSUpdates AutomaticallyInstallAppUpdates \
    CriticalUpdateInstall ConfigDataInstall; do
  [[ $(/usr/bin/defaults read "$SOFTWARE_UPDATE" "$key") == 0 ]] || {
    echo "ERROR: failed to disable $key" >&2
    exit 1
  }
done
[[ $(/usr/bin/defaults read "$COMMERCE" AutoUpdate) == 0 ]] || {
  echo "ERROR: failed to disable App Store automatic updates" >&2
  exit 1
}
[[ $(/usr/bin/defaults read "$COMMERCE" AutoUpdateRestartRequired) == 0 ]] || {
  echo "ERROR: failed to disable restart-required App Store updates" >&2
  exit 1
}

echo "manual_updates_only=enabled sequence=$CB_RELEASE_SEQUENCE"
