#!/bin/bash
# Install a reviewed signed-release client update from this release bundle.
set -euo pipefail

SOURCE=$(cd "$(dirname "$0")" && pwd)/cb-release-client.py
TARGET="/Library/Application Support/ChickenBlocker/release/cb-release-client.py"

[[ -f $SOURCE ]] || { echo "ERROR: release client payload is missing" >&2; exit 1; }
install -m 0755 -o root -g wheel "$SOURCE" "$TARGET.new"
/usr/bin/python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$TARGET.new"
mv "$TARGET.new" "$TARGET"
