#!/bin/bash
# Root-installed sudo target: live packet capture without root file access.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
is_uint() {
  case "$1" in
    0|[1-9]|[1-9][0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

CALLER=${SUDO_USER:-}
[ "$CALLER" = stevehuis ] || die "this wrapper is restricted to stevehuis"

OPTIONS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -i)
      [ "$#" -ge 2 ] || die "-i requires an interface"
      /sbin/ifconfig "$2" >/dev/null 2>&1 || die "unknown interface: $2"
      OPTIONS+=("$1" "$2")
      shift 2
      ;;
    -c)
      [ "$#" -ge 2 ] || die "-c requires a packet count"
      is_uint "$2" || die "packet count must be a non-negative integer"
      [ "$2" -ge 1 ] && [ "$2" -le 100000 ] || \
        die "packet count must be between 1 and 100000"
      OPTIONS+=("$1" "$2")
      shift 2
      ;;
    -s)
      [ "$#" -ge 2 ] || die "-s requires a snapshot length"
      is_uint "$2" || die "snapshot length must be a non-negative integer"
      [ "$2" -le 262144 ] || die "snapshot length exceeds 262144"
      OPTIONS+=("$1" "$2")
      shift 2
      ;;
    -A|-e|-l|-n|-nn|-q|-t|-tt|-ttt|-tttt|-ttttt|-U|-v|-vv|-vvv|-X|-XX)
      OPTIONS+=("$1")
      shift
      ;;
    --)
      shift
      break
      ;;
    -*) die "option is not allowed: $1" ;;
    *) break ;;
  esac
done

# -- prevents filter tokens from being reinterpreted as tcpdump options.
exec /usr/sbin/tcpdump -Z "$CALLER" -n "${OPTIONS[@]}" -- "$@"
