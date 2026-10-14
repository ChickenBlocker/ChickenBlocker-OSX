#!/bin/bash
# ChickenBlocker Phase 2 Santa staging. Profiles are always installed manually.
set -eu

BASE="/Library/Application Support/ChickenBlocker"
REPO="$(cd "$(dirname "$0")" && pwd)"
META="$REPO/config/santa-release.json"
CATALOG="$REPO/config/santa-rules.json"
GENERATED="$REPO/artifacts/generated"

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
require_mac() { [ "$(uname -s)" = Darwin ] || die "this stage must run on macOS"; }
pkg_path() { printf '%s/artifacts/%s' "$REPO" "$(meta pkg_filename)"; }
santactl_path() {
  command -v santactl 2>/dev/null || {
    [ -x /usr/local/bin/santactl ] && printf '%s\n' /usr/local/bin/santactl && return
    [ -x /Applications/Santa.app/Contents/MacOS/santactl ] && \
      printf '%s\n' /Applications/Santa.app/Contents/MacOS/santactl
  }
  return 0
}

validate_metadata() {
  version="$(meta version)"
  filename="$(meta pkg_filename)"
  url="$(meta pkg_url)"
  sha="$(meta pkg_sha256)"
  [ "$filename" = "santa-$version.pkg" ] || die "pinned filename/version mismatch"
  [ "${url##*/}" = "$filename" ] || die "pinned package URL mismatch"
  [ "${#sha}" = 64 ] || die "invalid pinned SHA-256"
  case "$sha" in *[!0-9a-f]*) die "invalid pinned SHA-256" ;; esac
  [ "$(meta team_id)" = ZMCG7MLDV9 ] || die "unexpected pinned Santa Team ID"
  [ "$(meta receipt_id)" = com.northpolesec.santa ] || die "unexpected Santa receipt ID"
  [ "$(meta receipt_version)" = 2026.8.244 ] || die "unexpected Santa receipt version"
  [ "$(meta system_extension_id)" = com.northpolesec.santa.daemon ] || \
    die "unexpected Santa system extension ID"
}

validate_pkg() {
  validate_metadata
  pkg="$(pkg_path)"
  [ -f "$pkg" ] || die "missing $pkg (run tools/fetch-santa.sh on the Mac)"
  expected="$(meta pkg_sha256)"
  actual="$(shasum -a 256 "$pkg" | cut -d ' ' -f 1)"
  [ "$actual" = "$expected" ] || die "Santa PKG SHA-256 mismatch"
  sig="$(pkgutil --check-signature "$pkg" 2>&1)" || die "Santa PKG signature is invalid"
  printf '%s\n' "$sig" | grep -F "Developer ID Installer: North Pole Security, Inc. ($(meta team_id))" >/dev/null || \
    die "Santa PKG installer identity mismatch"
  if printf '%s\n' "$sig" | grep -Fq "Status: signed by a developer certificate issued by Apple for distribution"; then
    printf '%s\n' "$sig" | grep -Fq "Notarization: trusted by the Apple notary service" || \
      die "Santa PKG is not trusted by the Apple notary service"
  else
    printf '%s\n' "$sig" | grep -Fq "Status: signed by a certificate trusted by Mac OS X" || \
      die "Santa PKG signing chain is not trusted"
  fi
  printf '%s\n' "$sig" | grep -Fq "Developer ID Certification Authority" || \
    die "Santa PKG chain is missing the Developer ID Certification Authority"
  printf '%s\n' "$sig" | grep -Fq "Apple Root CA" || die "Santa PKG chain is missing Apple Root CA"
}

fetch_package() {
  require_mac
  "$REPO/tools/fetch-santa.sh"
}

preflight() {
  require_mac
  command -v python3 >/dev/null 2>&1 || die "python3 is required"
  validate_metadata
  python3 "$REPO/tools/gen-santa-profile.py" production --catalog "$CATALOG" \
    --output-dir "${TMPDIR:-/tmp}/chickenblocker-santa-preflight" >/dev/null
  product="$(sw_vers -productVersion)"
  major="${product%%.*}"
  echo "macOS: $product"
  [ "$major" -ge 27 ] || die "Santa 2026.8 rollout was planned for macOS 27 or later"
  sip="$(csrutil status 2>&1 || true)"
  echo "$sip"
  printf '%s\n' "$sip" | grep -Fq 'System Integrity Protection status: enabled.' || \
    die "SIP must remain fully enabled"
  echo "Pinned release: $(meta version) ($(meta release_url))"
  if [ -f "$(pkg_path)" ]; then
    validate_pkg
    echo "Staged PKG: verified"
  else
    echo "Staged PKG: absent (run tools/fetch-santa.sh)"
  fi
  if receipt="$(pkgutil --pkg-info "$(meta receipt_id)" 2>/dev/null)"; then
    printf '%s\n' "$receipt"
    installed_version="$(printf '%s\n' "$receipt" | sed -n 's/^version: //p')"
    [ "$installed_version" = "$(meta receipt_version)" ] || \
      die "installed Santa receipt is $installed_version, expected $(meta receipt_version)"
  else
    echo "Installed Santa receipt: absent"
  fi
  SANTACTL="$(santactl_path)"
  if [ -n "$SANTACTL" ]; then
    echo "santactl: $SANTACTL"
    "$SANTACTL" version || true
    "$SANTACTL" status || true
  else
    echo "santactl: absent"
  fi
  echo ">> Endpoint Security clients"
  extension_state="$(systemextensionsctl list com.apple.system_extension.endpoint_security 2>&1 || true)"
  printf '%s\n' "$extension_state"
  if printf '%s\n' "$extension_state" | grep -F "$(meta system_extension_id)" | grep -Fq '[activated waiting for user]'; then
    echo
    echo "ACTION REQUIRED: macOS is still waiting for system-extension approval."
    echo "This is separate from Full Disk Access. Run:"
    echo "  bash '$REPO/install-santa.sh' request-extension-approval"
    echo "In Extensions, select By Category, click the circled info icon beside Endpoint"
    echo "Security Extensions, then enable Santa in the popup. Alternatively approve any banner"
    echo "under Privacy & Security. Do not enable Santa's network extension."
  fi
}

request_extension_approval() {
  require_mac
  santa="/Applications/Santa.app/Contents/MacOS/Santa"
  [ -x "$santa" ] || die "Santa.app is not installed"
  echo ">> Re-requesting Santa system-extension activation"
  "$santa" --load-system-extension || true
  open 'x-apple.systempreferences:com.apple.LoginItems-Settings.extension'
  echo "Activation was requested again. In Extensions, switch from By App to By"
  echo "Category, click the circled info icon beside Endpoint Security Extensions, and"
  echo "enable Santa in the popup. Also check for"
  echo "a blocked-system-software banner in Privacy & Security. Full Disk Access is separate."
}

open_extension_settings() {
  require_mac
  open 'x-apple.systempreferences:com.apple.LoginItems-Settings.extension'
  echo "Opened Login Items & Extensions. In Extensions, select By Category, click the"
  echo "circled info icon beside Endpoint Security Extensions, then enable Santa in the popup."
  echo "If that category is absent, check Privacy & Security for a blocked-system-software"
  echo "approval banner for Santa. Full Disk Access alone does not approve the extension."
}

install_package_root() {
  require_mac
  [ "$(id -u)" = 0 ] || die "run the printed sudo command"
  validate_pkg
  echo ">> Running Apple's installer for the verified pinned package"
  /usr/sbin/installer -pkg "$(pkg_path)" -target /
}

install_package() {
  require_mac
  validate_pkg
  cmd="sudo bash '$REPO/install-santa.sh' --install-package-root"
  echo "Validated the pinned package. Run this explicit privileged command:"
  echo "  $cmd"
}

generate_base_profiles() {
  mkdir -p "$GENERATED"
  python3 "$REPO/tools/gen-santa-profile.py" production --catalog "$CATALOG" --output-dir "$GENERATED"
  python3 "$REPO/tools/gen-santa-profile.py" rollback --output-dir "$GENERATED"
  if command -v plutil >/dev/null 2>&1; then
    for profile in "$GENERATED"/*.plist "$GENERATED"/*.mobileconfig; do
      plutil -lint "$profile"
    done
  fi
}

make_probe() {
  require_mac
  command -v clang >/dev/null 2>&1 || die "clang is required (install Xcode Command Line Tools)"
  SANTACTL="$(santactl_path)"
  [ -n "$SANTACTL" ] || die "Santa must be installed first"
  stamp="$(date +%Y%m%d%H%M%S)-$$"
  probe="/tmp/chickenblocker-santa-probe-$stamp"
  clang -Os -Wall -Wextra "-DCHICKENBLOCKER_PROBE_NONCE=\"$stamp\"" \
    -o "$probe" "$REPO/tools/santa-probe.c"
  hash="$("$SANTACTL" fileinfo --key SHA-256 "$probe")"
  [ "${#hash}" = 64 ] || die "santactl returned an invalid probe hash"
  case "$hash" in *[!0-9a-fA-F]*) die "santactl returned an invalid probe hash" ;; esac
  mkdir -p "$GENERATED"
  python3 "$REPO/tools/gen-santa-profile.py" probe --probe-sha256 "$hash" --output-dir "$GENERATED"
  plutil -lint "$GENERATED/com.chickenblocker.santa.probe.mobileconfig"
  echo
  echo "Probe: $probe"
  "$SANTACTL" fileinfo "$probe"
  echo
  static_count="$("$SANTACTL" status --json 2>/dev/null | \
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("daemon",{}).get("static_rules",0))' 2>/dev/null || echo 0)"
  if [ "$static_count" = 0 ]; then
    echo "Local-rule gate commands (run on this Mac in order):"
    echo "  '$probe'"
    echo "  sudo '$SANTACTL' rule --block --identifier '$hash' --message 'ChickenBlocker disposable probe'"
    echo "  '$probe'  # must be denied"
    echo "  '$SANTACTL' fileinfo --key Rule '$probe'"
    echo "  sudo '$SANTACTL' rule --remove --identifier '$hash'"
    echo "  '$probe'  # must run again"
  else
    echo "Santa currently has $static_count static rule(s); local rule changes are intentionally unavailable."
    echo "Distinct-probe gate command (do not install the newly generated profile):"
    echo "  '$probe'  # must run in Monitor mode"
  fi
}

stage_profile_root() {
  require_mac
  [ "$(id -u)" = 0 ] || die "run the printed sudo command"
  [ -f "$GENERATED/com.chickenblocker.santa.mobileconfig" ] || die "generate profiles first"
  [ -f "$GENERATED/com.chickenblocker.santa.rollback.mobileconfig" ] || die "rollback profile missing"
  install -d -o root -g wheel -m 0755 "$BASE" "$BASE/expected"
  install -m 0644 -o root -g wheel "$META" "$BASE/expected/santa-release.json"
  install -m 0644 -o root -g wheel "$CATALOG" "$BASE/expected/santa-rules.json"
  install -m 0755 -o root -g wheel "$REPO/daemon/cb-verifier.sh" "$BASE/verifier.sh"
  install -m 0644 -o root -g wheel "$GENERATED/com.chickenblocker.santa.mobileconfig" \
    "$BASE/expected/com.chickenblocker.santa.mobileconfig"
  install -m 0644 -o root -g wheel "$GENERATED/com.chickenblocker.santa.rollback.mobileconfig" \
    "$BASE/expected/com.chickenblocker.santa.rollback.mobileconfig"
  if [ -f "$GENERATED/com.chickenblocker.santa.probe.mobileconfig" ]; then
    install -m 0644 -o root -g wheel "$GENERATED/com.chickenblocker.santa.probe.mobileconfig" \
      "$BASE/expected/com.chickenblocker.santa.probe.mobileconfig"
  fi
  conf="$BASE/verifier.conf"
  [ -f "$conf" ] || die "install Phase 1 first so verifier.conf is preserved correctly"
  for setting in SANTA_CHECKS=0 SANTA_ENFORCE_SAFARI=0 SANTA_LOCAL_RULE_FALLBACK=1 SANTA_REINSTALL=0; do
    key="${setting%%=*}"
    grep -q "^$key=" "$conf" || printf '%s\n' "$setting" >> "$conf"
  done
  chown root:wheel "$conf"
  chmod 0644 "$conf"
  launchctl kickstart -k system/com.chickenblocker.verifier 2>/dev/null || true
  echo "Profiles staged under $BASE/expected; install them only through System Settings."
}

stage_profile() {
  require_mac
  generate_base_profiles
  echo "Profiles generated and linted. Run this explicit privileged staging command:"
  echo "  sudo bash '$REPO/install-santa.sh' --stage-profile-root"
}

verify() {
  require_mac
  verifier="$BASE/verifier.sh"
  [ -x "$verifier" ] || die "Phase 1 verifier is not installed"
  if [ "$(id -u)" != 0 ]; then
    echo "Run the Phase 2 audit with:"
    echo "  sudo '$BASE/bin/cb-bash' '$verifier' check"
    return
  fi
  "$BASE/bin/cb-bash" "$verifier" check
}

show_config() {
  require_mac
  conf="$BASE/verifier.conf"
  echo "ChickenBlocker Santa rollout flags:"
  if [ -r "$conf" ]; then
    echo "Current values in $conf:"
    grep '^SANTA_' "$conf" 2>/dev/null || echo "  no Santa flags yet; run stage-profile and its printed sudo command"
  else
    echo "Current config is not staged yet: $conf"
  fi
  echo
  echo "Required rollout sequence:"
  echo "  SANTA_CHECKS=0             while package/extension/FDA activation is incomplete"
  echo "  SANTA_CHECKS=1             after activated enabled and santactl doctor passes"
  echo "  SANTA_ENFORCE_SAFARI=0     through local-rule, StaticRules, and rollback probes"
  echo "  SANTA_ENFORCE_SAFARI=1     only after the production profile blocks live Safari"
  echo "  SANTA_LOCAL_RULE_FALLBACK=1 keep the exact temporary Safari fallback enabled"
  echo "  SANTA_REINSTALL=0          keep automatic package reinstall disabled"
  echo
  echo "Edit explicitly with:"
  echo "  sudo nano '$conf'"
}

transport() {
  target="$1"
  stage="$2"
  ssh -o BatchMode=yes "$target" true || die "cannot reach $target over SSH"
  [ "$(ssh -o BatchMode=yes "$target" 'uname -s')" = Darwin ] || die "$target is not a Mac"
  remote="/tmp/chickenblocker-osx-santa"
  echo ">> Copying Phase 2 files to $target:$remote"
  tar -cf - -C "$REPO" install-santa.sh config daemon tools | \
    ssh "$target" "mkdir -p '$remote' && tar -C '$remote' -xf -"
  if [ -d "$REPO/artifacts" ]; then
    tar -cf - -C "$REPO" artifacts | ssh "$target" "tar -C '$remote' -xf -"
  fi
  echo ">> Running unprivileged stage '$stage' on $target"
  ssh -t "$target" "bash '$remote/install-santa.sh' '$stage'"
  echo "Remote files remain at $remote so any printed sudo command is visible and user-initiated."
  case "$stage" in
    install-package)
      echo "Run the package installation from this machine with:"
      echo "  ssh -t '$target' \"sudo bash '$remote/install-santa.sh' --install-package-root\""
      ;;
    stage-profile)
      echo "Run profile/verifier staging from this machine with:"
      echo "  ssh -t '$target' \"sudo bash '$remote/install-santa.sh' --stage-profile-root\""
      ;;
    show-config)
      echo "To edit this config remotely, run:"
      echo "  ssh -t '$target' \"sudo nano '$BASE/verifier.conf'\""
      ;;
  esac
}

usage() {
  echo "usage: $0 {fetch|preflight|install-package|request-extension-approval|open-extension-settings|make-probe|stage-profile|show-config|verify} [user@mac-host]"
}

case "${1:-}" in
  --install-package-root) install_package_root ;;
  --stage-profile-root) stage_profile_root ;;
  fetch|preflight|install-package|request-extension-approval|open-extension-settings|make-probe|stage-profile|show-config|verify)
    stage="$1"
    if [ -n "${2:-}" ]; then
      transport "$2" "$stage"
    else
      case "$stage" in
        fetch) fetch_package ;;
        preflight) preflight ;;
        install-package) install_package ;;
        request-extension-approval) request_extension_approval ;;
        open-extension-settings) open_extension_settings ;;
        make-probe) make_probe ;;
        stage-profile) stage_profile ;;
        show-config) show_config ;;
        verify) verify ;;
      esac
    fi
    ;;
  -h|--help|help|"") usage ;;
  *) usage >&2; exit 2 ;;
esac
