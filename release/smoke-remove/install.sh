#!/bin/bash
# Remove the harmless signed-release smoke-test marker.
set -euo pipefail

rm -f "/Library/Application Support/ChickenBlocker/release-smoke-marker"
