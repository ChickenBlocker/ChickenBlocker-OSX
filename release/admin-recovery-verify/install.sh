#!/bin/bash
# Verify the temporary recovery-test administrator is fully removed.
set -euo pipefail

ACCOUNT=cb-release-admin-test
MARKER=/var/db/chickenblocker-release-admin-test

[[ $(uname -s) == Darwin && $EUID -eq 0 ]] || {
  echo "ERROR: admin recovery verification requires macOS root" >&2
  exit 1
}
[[ ${CB_RELEASE_SEQUENCE:-} =~ ^[1-9][0-9]*$ ]] || {
  echo "ERROR: invalid release sequence" >&2
  exit 1
}

if /usr/bin/id "$ACCOUNT" >/dev/null 2>&1 || \
   /usr/bin/dscl . -read "/Users/$ACCOUNT" >/dev/null 2>&1; then
  echo "ERROR: temporary admin still present: $ACCOUNT" >&2
  exit 1
fi

rm -f "$MARKER"
rm -rf "/Users/$ACCOUNT"
echo "verified temporary admin removed: $ACCOUNT"
