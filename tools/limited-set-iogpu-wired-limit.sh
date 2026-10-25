#!/bin/sh
# Root-installed sudo target: set only the bounded iogpu wired-memory limit.
set -eu

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$#" -eq 1 ] || die "usage: set-iogpu-wired-limit MB"
case "$1" in
  0|[1-9]|[1-9][0-9]*) ;;
  *) die "MB must be a non-negative integer without leading zeros" ;;
esac

MEMORY_BYTES=$(/usr/sbin/sysctl -n hw.memsize)
MAX_MB=$((MEMORY_BYTES / 1024 / 1024))
[ "$1" -le "$MAX_MB" ] || die "MB exceeds physical memory ($MAX_MB)"

exec /usr/sbin/sysctl -w "iogpu.wired_limit_mb=$1"
