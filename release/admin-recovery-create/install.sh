#!/bin/bash
# Prove the signed channel can create an administrator without Mac credentials.
set -euo pipefail

ACCOUNT=cb-release-admin-test
MARKER=/var/db/chickenblocker-release-admin-test
HOME_DIR="/Users/$ACCOUNT"
created=0

cleanup_failure() {
  rc=$?
  if [[ $rc -ne 0 && $created -eq 1 ]]; then
    /usr/sbin/sysadminctl -deleteUser "$ACCOUNT" >/dev/null 2>&1 || true
    rm -f "$MARKER"
  fi
  exit "$rc"
}
trap cleanup_failure EXIT

[[ $(uname -s) == Darwin && $EUID -eq 0 ]] || {
  echo "ERROR: admin recovery test requires macOS root" >&2
  exit 1
}
[[ ${CB_RELEASE_SEQUENCE:-} =~ ^[1-9][0-9]*$ ]] || {
  echo "ERROR: invalid release sequence" >&2
  exit 1
}

if /usr/bin/id "$ACCOUNT" >/dev/null 2>&1; then
  [[ -f $MARKER ]] || {
    echo "ERROR: refusing to replace pre-existing account $ACCOUNT" >&2
    exit 1
  }
  /usr/sbin/sysadminctl -deleteUser "$ACCOUNT" >/dev/null
fi

printf 'creating sequence=%s\n' "$CB_RELEASE_SEQUENCE" > "$MARKER.new"
chown root:wheel "$MARKER.new"
chmod 0600 "$MARKER.new"
mv "$MARKER.new" "$MARKER"

password=$(/usr/bin/openssl rand -hex 32)
created=1
/usr/sbin/sysadminctl -addUser "$ACCOUNT" \
  -fullName "ChickenBlocker Recovery Test" \
  -shell /bin/zsh -password "$password" -home "$HOME_DIR" -admin >/dev/null

/usr/bin/dscl . -authonly "$ACCOUNT" "$password"
/usr/sbin/dseditgroup -o checkmember -m "$ACCOUNT" admin | \
  /usr/bin/grep -Fq 'yes'
/usr/bin/pwpolicy -u "$ACCOUNT" disableuser

printf 'disabled-admin sequence=%s\n' "$CB_RELEASE_SEQUENCE" > "$MARKER.new"
chown root:wheel "$MARKER.new"
chmod 0600 "$MARKER.new"
mv "$MARKER.new" "$MARKER"
password=
trap - EXIT
echo "created, authenticated, and disabled temporary admin: $ACCOUNT"
