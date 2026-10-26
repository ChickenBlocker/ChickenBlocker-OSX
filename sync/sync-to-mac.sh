#!/bin/bash
# ChickenBlocker-OSX rule release staging — runs on the rule-source machine.
#
# Extracts the live rules (LeechBlock settings snapshot, Page Keyword Filter
# keyword list, signed PKF .xpi — see extract_rules.py), builds a fixed-action
# signed-release bundle, and optionally uploads it to the admin appliance's
# unprivileged staging directory. It never connects to the protected Mac or
# invokes Mac sudo.
#
# Usage:
#   sync/sync-to-mac.sh
#   sync/sync-to-mac.sh mdm-admin@10.11.133.222
#   CB_RELEASE_APPLIANCE=mdm-admin@10.11.133.222 sync/sync-to-mac.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
STAGED="$REPO/staged"
OUTPUT="$REPO/.release-staging/rules"
APPLIANCE="${1:-${CB_RELEASE_APPLIANCE:-}}"
REMOTE_PATH=chickenblocker-release-staging/rules

python3 "$REPO/sync/extract_rules.py" --out "$STAGED"
/usr/bin/python3 "$REPO/tools/build-release-bundle.py" rules \
  --source "$STAGED" --output "$OUTPUT"

if [[ -z $APPLIANCE ]]; then
  echo "Rules release staged locally: $OUTPUT"
  echo "Upload with: $0 mdm-admin@10.11.133.222"
  exit 0
fi

ssh -o BatchMode=yes "$APPLIANCE" \
  'rm -rf "$HOME/chickenblocker-release-staging/rules" && mkdir -p "$HOME/chickenblocker-release-staging/rules"'
tar -C "$OUTPUT" -cf - . | ssh -o BatchMode=yes "$APPLIANCE" \
  'tar -C "$HOME/chickenblocker-release-staging/rules" -xf -'
echo "Rules release staged on $APPLIANCE:$REMOTE_PATH"
echo "Review it, then publish an explicit next sequence from the appliance console:"
echo "  cb-publish-release --bundle /home/mdm-admin/$REMOTE_PATH --sequence N"
