#!/bin/bash
# Harmless end-to-end proof that a signed release ran as root.
set -euo pipefail

MARKER="/Library/Application Support/ChickenBlocker/release-smoke-marker"
printf 'release=%s\n' "${CB_RELEASE_SEQUENCE:?}" > "$MARKER.new"
chown root:wheel "$MARKER.new"
chmod 0644 "$MARKER.new"
mv "$MARKER.new" "$MARKER"
