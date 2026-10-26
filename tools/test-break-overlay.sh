#!/bin/bash
# Compile and show a short, unprivileged overlay using a temporary command file.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cb-break-overlay.XXXXXX")
PID=""
cleanup() {
  [ -z "$PID" ] || kill "$PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

UNTIL=$(($(date +%s) + 30))
python3 - "$TMP/command.json" "$UNTIL" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({
        "mode": "break",
        "until": int(sys.argv[2]),
        "kind": "test",
        "message": "ChickenBlocker break overlay test",
        "allow_escape": True,
    }, handle)
PY

xcrun swiftc -parse-as-library "$REPO/agent/cb-break-overlay.swift" \
  -o "$TMP/cb-break-overlay"
CB_BREAK_COMMAND_PATH="$TMP/command.json" \
CB_BREAK_REQUEST_PATH="$TMP/request.json" "$TMP/cb-break-overlay" &
PID=$!
sleep 30
