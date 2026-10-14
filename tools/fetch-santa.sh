#!/bin/bash
# Download and validate the exact Santa release pinned in config/santa-release.json.
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
META="$REPO/config/santa-release.json"
ARTIFACTS="$REPO/artifacts"

die() { echo "ERROR: $*" >&2; exit 1; }
meta() {
  python3 - "$META" "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle).get(sys.argv[2])
if not isinstance(value, str) or not value:
    raise SystemExit("missing metadata key: " + sys.argv[2])
print(value)
PY
}

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v curl >/dev/null 2>&1 || die "curl is required"
version="$(meta version)"
filename="$(meta pkg_filename)"
url="$(meta pkg_url)"
expected_sha="$(meta pkg_sha256)"
team_id="$(meta team_id)"
[ "$filename" = "santa-$version.pkg" ] || die "pinned filename/version mismatch"
[ "${url##*/}" = "$filename" ] || die "pinned URL filename mismatch"
[ "${#expected_sha}" = 64 ] || die "invalid SHA-256 metadata"
case "$expected_sha" in *[!0-9a-f]*) die "invalid SHA-256 metadata" ;; esac

mkdir -p "$ARTIFACTS"
pkg="$ARTIFACTS/$filename"
tmp="$pkg.partial"
rm -f "$tmp"
actual_sha=""
if [ -f "$pkg" ]; then
  actual_sha="$(shasum -a 256 "$pkg" | cut -d ' ' -f 1)"
fi
if [ "$actual_sha" = "$expected_sha" ]; then
  echo ">> Reusing checksum-verified $pkg"
else
  echo ">> Downloading $url"
  curl --fail --location --proto '=https' --tlsv1.2 --output "$tmp" "$url"
  actual_sha="$(shasum -a 256 "$tmp" | cut -d ' ' -f 1)"
  [ "$actual_sha" = "$expected_sha" ] || {
    rm -f "$tmp"
    die "SHA-256 mismatch: expected $expected_sha, got $actual_sha"
  }
  mv "$tmp" "$pkg"
fi

[ "$(uname -s)" = Darwin ] || die "checksum verified, but trusted PKG signature verification must run on macOS"
command -v pkgutil >/dev/null 2>&1 || die "pkgutil is required"
signature="$(pkgutil --check-signature "$pkg" 2>&1)" || die "pkgutil rejected the package signature"
printf '%s\n' "$signature"
printf '%s\n' "$signature" | grep -F "Developer ID Installer: North Pole Security, Inc. ($team_id)" >/dev/null || \
  die "installer identity is not North Pole Security, Inc. ($team_id)"
if printf '%s\n' "$signature" | grep -Fq "Status: signed by a developer certificate issued by Apple for distribution"; then
  printf '%s\n' "$signature" | grep -Fq "Notarization: trusted by the Apple notary service" || \
    die "installer is not trusted by the Apple notary service"
else
  printf '%s\n' "$signature" | grep -Fq "Status: signed by a certificate trusted by Mac OS X" || \
    die "installer certificate chain is not trusted"
fi
printf '%s\n' "$signature" | grep -Fq "Developer ID Certification Authority" || \
  die "installer chain is missing the Developer ID Certification Authority"
printf '%s\n' "$signature" | grep -Fq "Apple Root CA" || die "installer chain is missing Apple Root CA"

echo "Verified Santa $version: $pkg"
echo "SHA-256: $actual_sha"
echo "Release: $(meta release_url)"
