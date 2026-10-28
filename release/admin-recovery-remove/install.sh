#!/bin/bash
# Remove the temporary administrator created by the recovery-channel test.
set -euo pipefail

ACCOUNT=cb-release-admin-test
MARKER=/var/db/chickenblocker-release-admin-test

[[ $(uname -s) == Darwin && $EUID -eq 0 ]] || {
  echo "ERROR: admin recovery cleanup requires macOS root" >&2
  exit 1
}
[[ ${CB_RELEASE_SEQUENCE:-} =~ ^[1-9][0-9]*$ ]] || {
  echo "ERROR: invalid release sequence" >&2
  exit 1
}

if /usr/bin/id "$ACCOUNT" >/dev/null 2>&1; then
  [[ -f $MARKER ]] || {
    echo "ERROR: refusing to remove account without test marker: $ACCOUNT" >&2
    exit 1
  }
  /usr/bin/pwpolicy -u "$ACCOUNT" enableuser >/dev/null 2>&1 || true
  /usr/sbin/dseditgroup -o edit -d "$ACCOUNT" -t user admin >/dev/null 2>&1 || true
  /usr/sbin/sysadminctl -deleteUser "$ACCOUNT" >/dev/null 2>&1 || true
  if /usr/bin/dscl . -read "/Users/$ACCOUNT" >/dev/null 2>&1; then
    /usr/bin/dscl . -delete "/Users/$ACCOUNT"
  fi
fi

if /usr/bin/id "$ACCOUNT" >/dev/null 2>&1 || \
   /usr/bin/dscl . -read "/Users/$ACCOUNT" >/dev/null 2>&1; then
  echo "ERROR: temporary admin record remains: $ACCOUNT" >&2
  exit 1
fi
rm -rf "/Users/$ACCOUNT"
rm -f "$MARKER"
echo "removed temporary admin: $ACCOUNT"
