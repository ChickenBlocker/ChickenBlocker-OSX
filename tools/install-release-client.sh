#!/bin/bash
# Bootstrap the root signed-release pull client on the protected Mac.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
BASE="/Library/Application Support/ChickenBlocker/release"
PLIST=/Library/LaunchDaemons/com.chickenblocker.release.plist
PUBLIC_KEY=${1:-}
BASE_URL=${2:-http://10.11.133.222:8443}

if [[ $(uname -s) != Darwin ]]; then
  echo "ERROR: this installer must run on macOS" >&2
  exit 1
fi
if [[ $EUID -ne 0 ]]; then
  exec sudo /bin/bash "$0" "$@"
fi
if [[ -z $PUBLIC_KEY || ! -f $PUBLIC_KEY ]]; then
  echo "usage: $0 /path/to/signing-public.pem [release-base-url]" >&2
  exit 2
fi
if [[ ! $BASE_URL =~ ^https?://[A-Za-z0-9.:-]+$ ]]; then
  echo "ERROR: invalid release base URL" >&2
  exit 2
fi
command -v python3 >/dev/null || { echo "ERROR: python3 is required" >&2; exit 1; }
[[ -x /usr/bin/openssl ]] || { echo "ERROR: /usr/bin/openssl is required" >&2; exit 1; }

install -d -o root -g wheel -m 0755 "$BASE"
install -d -o root -g wheel -m 0700 "$BASE/state"
install -m 0755 -o root -g wheel "$REPO/daemon/cb-release-client.py" \
  "$BASE/cb-release-client.py"
install -m 0644 -o root -g wheel "$PUBLIC_KEY" "$BASE/signing-public.pem"
printf '{"audit":true,"base_url":"%s"}\n' "$BASE_URL" > "$BASE/config.json"
chown root:wheel "$BASE/config.json"
chmod 0644 "$BASE/config.json"
install -m 0644 -o root -g wheel \
  "$REPO/daemon/com.chickenblocker.release.plist" "$PLIST"

launchctl bootout system/com.chickenblocker.release 2>/dev/null || true
launchctl bootstrap system "$PLIST"
launchctl print system/com.chickenblocker.release >/dev/null

echo "Installed com.chickenblocker.release"
echo "Pinned public-key fingerprint:"
/usr/bin/openssl pkey -pubin -in "$BASE/signing-public.pem" -outform DER 2>/dev/null | \
  /usr/bin/shasum -a 256
