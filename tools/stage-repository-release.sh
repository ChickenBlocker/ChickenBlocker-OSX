#!/bin/bash
# Build a reviewed repository bundle and optionally stage it on the appliance.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
OUTPUT="$REPO/.release-staging/repository"
APPLIANCE=${1:-${CB_RELEASE_APPLIANCE:-}}
REMOTE_PATH=chickenblocker-release-staging/repository

[[ $EUID -ne 0 ]] || { echo "ERROR: run as the source user, not root" >&2; exit 1; }
/usr/bin/python3 "$REPO/tools/build-release-bundle.py" repository \
  --source "$REPO" --output "$OUTPUT"

if [[ -z $APPLIANCE ]]; then
  echo "Repository release staged locally: $OUTPUT"
  echo "Upload with: $0 mdm-admin@10.11.133.222"
  exit 0
fi

ssh -o BatchMode=yes "$APPLIANCE" \
  'rm -rf "$HOME/chickenblocker-release-staging/repository" && mkdir -p "$HOME/chickenblocker-release-staging/repository"'
tar -C "$OUTPUT" -cf - . | ssh -o BatchMode=yes "$APPLIANCE" \
  'tar -C "$HOME/chickenblocker-release-staging/repository" -xf -'
echo "Repository release staged on $APPLIANCE:$REMOTE_PATH"
echo "Review it, then publish an explicit next sequence from the appliance console:"
echo "  cb-publish-release --bundle /home/mdm-admin/$REMOTE_PATH --sequence N"
