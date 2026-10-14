#!/bin/bash
# ChickenBlocker-OSX rule sync — runs on the LINUX ChickenBlocker machine.
#
# Extracts the live rules (LeechBlock settings snapshot, Page Keyword Filter
# keyword list, signed PKF .xpi — see extract_rules.py), then pushes them to
# the Mac's ChickenBlocker-OSX install and triggers a repair + audit there.
# SSH is used ONLY when a target is provided.
#
# Usage:
#   sync/sync-to-mac.sh user@mac-host     extract + push + audit
#   sync/sync-to-mac.sh                   extract only (stage into ./staged)
#   CB_MAC_TARGET=user@mac-host sync/sync-to-mac.sh
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
STAGED="$REPO/staged"
TARGET="${1:-${CB_MAC_TARGET:-}}"

python3 "$REPO/sync/extract_rules.py" --out "$STAGED"

cat > "$STAGED/sync-remote.sh" <<'EOF'
#!/bin/bash
set -eu
cd "$(dirname "$0")"
BASE="/Library/Application Support/ChickenBlocker"
if [ ! -d "$BASE/expected" ]; then
  echo "ERROR: ChickenBlocker-OSX is not installed on this Mac (run install.sh first)" >&2
  exit 1
fi
install -d -o root -g wheel -m 0755 "$BASE/expected/extensions"
found=0
for f in leechblockng-managed-storage.json pkf-managed-storage.json; do
  if [ -f "$f" ]; then
    install -m 0644 -o root -g wheel "$f" "$BASE/expected/$f"
    echo "updated expected/$f"
    found=1
  fi
done
if [ -f extensions/page_keyword_filter.xpi ]; then
  install -m 0644 -o root -g wheel extensions/page_keyword_filter.xpi \
    "$BASE/expected/extensions/page_keyword_filter.xpi"
  echo "updated expected/extensions/page_keyword_filter.xpi"
  found=1
fi
if [ "$found" = 0 ]; then
  echo "ERROR: no staged rule files found next to sync-remote.sh" >&2
  exit 1
fi
echo ">> Applying (repair pass)"
bash "$BASE/verifier.sh" repair
echo ">> Audit"
exec bash "$BASE/verifier.sh" check
EOF

if [ -z "$TARGET" ]; then
  echo "Staged only (no SSH target given): $STAGED"
  echo "Push with: $0 user@mac-host"
  exit 0
fi

ssh -o BatchMode=yes "$TARGET" true || {
  echo "ERROR: cannot reach $TARGET over SSH (key-based login required)" >&2
  exit 1
}
RT="$(ssh "$TARGET" 'mktemp -d /tmp/cbosx-sync.XXXXXX')"
cleanup() { ssh "$TARGET" "rm -rf '$RT'" 2>/dev/null || true; }
trap cleanup EXIT

echo ">> Pushing staged rules to $TARGET"
tar -C "$STAGED" -cf - . | ssh "$TARGET" "tar -C '$RT' -xf -"

echo ">> Installing rules on $TARGET (sudo password may be asked)"
ssh -t "$TARGET" "sudo bash '$RT/sync-remote.sh'"
