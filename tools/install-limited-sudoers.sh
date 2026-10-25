#!/bin/bash
# Install the root-owned daily-command wrappers and sudoers policy.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

REPO=$(cd "$(dirname "$0")/.." && pwd)
POLICY="$REPO/config/sudoers-limited"
LIBEXEC=/usr/local/libexec/chickenblocker

[ "$(uname -s)" = Darwin ] || die "this installer must run on macOS"
if [ "$(id -u)" -ne 0 ]; then
  exec /usr/bin/sudo /bin/bash "$0" "$@"
fi

/usr/sbin/visudo -cf "$POLICY"
/usr/bin/install -d -o root -g wheel -m 0755 "$LIBEXEC"
/usr/bin/install -o root -g wheel -m 0755 \
  "$REPO/tools/limited-set-iogpu-wired-limit.sh" \
  "$LIBEXEC/set-iogpu-wired-limit"
/usr/bin/install -o root -g wheel -m 0755 \
  "$REPO/tools/limited-tcpdump.sh" "$LIBEXEC/tcpdump"
/usr/bin/install -o root -g wheel -m 0440 \
  "$POLICY" /etc/sudoers.d/limited

/usr/sbin/visudo -c
/usr/bin/sudo -l -U stevehuis
