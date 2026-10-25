#!/bin/bash
# ChickenBlocker-OSX verifier — Firefox policy + LeechBlock rule check & repair.
#
# Modes:
#   daemon  check and repair forever (used by the LaunchDaemon)
#   repair  one check-and-repair pass
#   check   audit only: PASS/FAIL/SKIP report, exit 1 on any FAIL
#
# Canonical ("expected") files live under BASE/expected and are installed by
# install.sh (Firefox policies) and sync-to-mac.sh (LeechBlock + keyword
# rules, pushed from the Linux ChickenBlocker machine). Live targets:
#   <Firefox.app>/Contents/Resources/distribution/policies.json
#   /Library/Application Support/Mozilla/ManagedStorage/leechblockng@proginosko.com.json
#   /Library/Application Support/Mozilla/ManagedStorage/page-keyword-filter-7f3a@local.addons.json
#   BASE/extensions/page_keyword_filter.xpi
#   <Firefox profile>/chrome/userChrome.css and userContent.css
#
# Extension enforcement (ports the Linux ChickenBlocker daemon): every Firefox
# profile's extensions.json is checked for a disabled/missing LeechBlock or
# Page Keyword Filter entry. On drift: Firefox is quit, the entry is re-enabled
# in extensions.json, the addonStartup cache is dropped, and Firefox is
# relaunched — but only if it was running before (never started on its own).
# Private-window grants require Firefox's internal permission API and are
# enforced by the Firefox policy profile, not by unsupported file mutation.
#
# Config: BASE/verifier.conf — CHECK_INTERVAL (seconds, default 15),
#         RESTART_FIREFOX_ON_REPAIR (0/1, default 1: when a managed-storage
#         file had to be repaired while Firefox is running, quit and relaunch
#         Firefox so LeechBlock re-copies the managed configuration).
#         Extension enforcement is NOT governed by this flag (it is the core
#         enforcement, mirroring Linux).
#
# Phase 2 optionally audits Santa and its explicit Safari SigningID rule. Santa
# remains in Monitor mode; the rule is the execution boundary. This is still a
# local friction layer because an administrator can remove a local profile.
set -u

BASE="/Library/Application Support/ChickenBlocker"
EXPECTED="$BASE/expected"
LOGFILE="$BASE/verifier.log"
CONF="$BASE/verifier.conf"
PLIST="/Library/LaunchDaemons/com.chickenblocker.verifier.plist"
CHECK_INTERVAL=15
RESTART_FIREFOX_ON_REPAIR=1
EXT_RESTART_MIN_INTERVAL=300
SANTA_CHECKS=0
SANTA_ENFORCE_SAFARI=0
SANTA_LOCAL_RULE_FALLBACK=1
SANTA_REINSTALL=0
SANTA_REPAIR_MIN_INTERVAL=60
[ -r "$CONF" ] && . "$CONF"

LB_ID="leechblockng@proginosko.com"
PKF_ID="page-keyword-filter-7f3a@local.addons"
MS_DIR="/Library/Application Support/Mozilla/ManagedStorage"

MODE="${1:-daemon}"
case "$MODE" in
  daemon|repair|check) ;;
  *) echo "usage: $0 [daemon|repair|check]" >&2; exit 2 ;;
esac

PASS=0
FAIL=0
SKIP=0
REPAIRED=0
REPAIRED_MANAGED=0
REPAIRED_RESTART=0
FIREFOX_POLICY_RESTART=0
FIREFOX_POLICY_HEALTHY=0
EXT_DRIFT_PROFILES=""
CONSOLE_USER=""
CONSOLE_UID=""
SANTA_PROFILE_STATE="unchecked"
SANTA_STATIC_COUNT=""
SANTA_HEALTHY=0
SAFARI_EXE=""
SAFARI_PIDS=""
SAFARI_SIGNING_ID="platform:com.apple.Safari"
SANTA_VERSION="2026.8"
SANTA_RECEIPT_VERSION="2026.8.244"
SANTA_TEAM_ID="ZMCG7MLDV9"
SANTA_RECEIPT_ID="com.northpolesec.santa"
SANTA_EXTENSION_ID="com.northpolesec.santa.daemon"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGFILE" 2>/dev/null || true
  if [ -f "$LOGFILE" ]; then
    z="$(stat -f %z "$LOGFILE" 2>/dev/null || echo 0)"
    if [ "$z" -gt 131072 ]; then
      tail -n 400 "$LOGFILE" > "$LOGFILE.cbtmp" 2>/dev/null && mv "$LOGFILE.cbtmp" "$LOGFILE"
    fi
  fi
}

audit_pass() {
  PASS=$((PASS+1))
  [ "$MODE" = check ] && echo "  [PASS] $1 — $2"
}

audit_skip() {
  SKIP=$((SKIP+1))
  [ "$MODE" = check ] && echo "  [SKIP] $1 — $2"
}

warn_limited() {
  label="$1"
  message="$2"
  stamp="$BASE/.${label}-warn-last"
  now="$(date +%s)"
  last="$(cat "$stamp" 2>/dev/null || echo 0)"
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now - last)) -ge 3600 ]; then
    echo "$now" > "$stamp" 2>/dev/null || true
    log "WARN $label: $message"
  fi
}

audit_fail() {
  FAIL=$((FAIL+1))
  if [ "$MODE" = check ]; then
    echo "  [FAIL] $1 — $2"
  else
    warn_limited "$1" "$2"
  fi
}

santactl_path() {
  command -v santactl 2>/dev/null || {
    [ -x /usr/local/bin/santactl ] && printf '%s\n' /usr/local/bin/santactl && return
    [ -x /Applications/Santa.app/Contents/MacOS/santactl ] && \
      printf '%s\n' /Applications/Santa.app/Contents/MacOS/santactl
  }
  return 0
}

safari_executable() {
  app="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.Safari'" 2>/dev/null | while IFS= read -r candidate; do
    [ -d "$candidate" ] && { printf '%s\n' "$candidate"; break; }
  done)"
  [ -n "$app" ] || app="/Applications/Safari.app"
  [ -d "$app" ] || return 1
  executable="$(plutil -extract CFBundleExecutable raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)"
  [ -n "$executable" ] || return 1
  [ -f "$app/Contents/MacOS/$executable" ] || return 1
  printf '%s\n' "$app/Contents/MacOS/$executable"
}

profile_state() {
  canonical="$1"
  python3 - "$canonical" <<'PY'
import os
import plistlib
import sys

canonical_path = sys.argv[1]
managed_path = "/Library/Managed Preferences/com.northpolesec.santa.plist"
try:
    with open(canonical_path, "rb") as handle:
        expected_profile = plistlib.load(handle)
    expected = expected_profile["PayloadContent"][0]
except Exception as error:
    print("canonical-error:" + str(error))
    raise SystemExit(0)

if not os.path.exists(managed_path):
    print("absent")
    raise SystemExit(0)
try:
    with open(managed_path, "rb") as handle:
        installed = plistlib.load(handle)
except Exception:
    print("unreadable")
    raise SystemExit(0)

keys = (
    "ClientMode", "EnableNotificationSilences", "EnableSilentMode",
    "EnableSilentTTYMode", "StaticRules")
expected_subset = {key: expected.get(key) for key in keys}
installed_subset = {key: installed.get(key) for key in keys}
allowed_keys = set(keys) | {"PayloadUUID", "_manualProfile"}
if (installed_subset == expected_subset and
        installed.get("PayloadUUID") == expected.get("PayloadUUID") and
        set(installed).issubset(allowed_keys)):
    print("ok")
    raise SystemExit(0)
print("mismatch")
PY
}

pid_executable() {
  pid="$1"
  path="$(ps -p "$pid" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//')"
  if [ ! -f "$path" ] && command -v lsof >/dev/null 2>&1; then
    path="$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | sed -n '1p')"
  fi
  [ -f "$path" ] || return 1
  printf '%s\n' "$path"
}

check_santa() {
  if [ "$SANTA_CHECKS" != 1 ]; then
    audit_skip "santa-checks" "disabled in verifier.conf until Santa activation is complete"
    return
  fi
  if [ "$(id -u)" != 0 ]; then
    audit_skip "santa-checks" "needs root (sudo)"
    return
  fi

  SANTA_HEALTHY=1
  info="$(pkgutil --pkg-info "$SANTA_RECEIPT_ID" 2>/dev/null || true)"
  receipt_version="$(printf '%s\n' "$info" | sed -n 's/^version: //p')"
  if [ "$receipt_version" = "$SANTA_RECEIPT_VERSION" ]; then
    audit_pass "santa-package" "receipt $SANTA_RECEIPT_ID version $receipt_version"
  else
    audit_fail "santa-package" "expected receipt version $SANTA_RECEIPT_VERSION, found ${receipt_version:-none}; automatic reinstall is disabled"
    SANTA_HEALTHY=0
  fi

  signature="$(codesign -dv --verbose=4 /Applications/Santa.app 2>&1 || true)"
  if codesign --verify --deep --strict /Applications/Santa.app >/dev/null 2>&1 &&
     printf '%s\n' "$signature" | grep -q "^TeamIdentifier=$SANTA_TEAM_ID$"; then
    audit_pass "santa-signature" "Santa.app Team ID $SANTA_TEAM_ID"
  else
    audit_fail "santa-signature" "Santa.app is absent or not signed by Team ID $SANTA_TEAM_ID"
    SANTA_HEALTHY=0
  fi

  extension_state="$(systemextensionsctl list com.apple.system_extension.endpoint_security 2>&1 || true)"
  if printf '%s\n' "$extension_state" | grep -F "$SANTA_EXTENSION_ID" | grep -Fq '[activated enabled]'; then
    audit_pass "santa-system-extension" "$SANTA_EXTENSION_ID is activated enabled"
  else
    audit_fail "santa-system-extension" "$SANTA_EXTENSION_ID is not activated enabled"
    SANTA_HEALTHY=0
  fi

  SANTACTL="$(santactl_path)"
  status_json=""
  doctor=""
  if [ -n "$SANTACTL" ]; then
    status_json="$("$SANTACTL" status --json 2>/dev/null || true)"
  fi
  doctor="$("$SANTACTL" doctor 2>&1 || true)"
  doctor_failure="$(printf '%s\n' "$doctor" | grep -F -m1 '[-]' || true)"
  if [ -n "$status_json" ] && [ -z "$doctor_failure" ]; then
    audit_pass "santa-fda" "daemon communication succeeded and santactl doctor reported no failed checks"
  else
    detail="$(printf '%s\n' "${doctor:-santactl status could not communicate with the daemon}" | grep -i -m1 -E 'Full Disk Access|\[-\]' || true)"
    audit_fail "santa-fda" "${detail:-santactl status/doctor failed; verify Full Disk Access}"
    SANTA_HEALTHY=0
  fi

  mode="$(printf '%s' "$status_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("daemon",{}).get("mode",""))' 2>/dev/null || true)"
  SANTA_STATIC_COUNT="$(printf '%s' "$status_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("daemon",{}).get("static_rules",""))' 2>/dev/null || true)"
  if [ "$mode" = Monitor ]; then
    audit_pass "santa-mode" "Monitor"
  else
    audit_fail "santa-mode" "expected Monitor, found ${mode:-unknown}; verifier will never change client mode"
    SANTA_HEALTHY=0
  fi

  SAFARI_EXE="$(safari_executable 2>/dev/null || true)"
  signing_id=""
  if [ -n "$SAFARI_EXE" ] && [ -n "$SANTACTL" ]; then
    signing_id="$("$SANTACTL" fileinfo --key 'Signing ID' "$SAFARI_EXE" 2>/dev/null || true)"
  fi
  if [ "$signing_id" = "$SAFARI_SIGNING_ID" ]; then
    audit_pass "santa-safari-identity" "$SAFARI_EXE resolves to $signing_id"
  else
    audit_fail "santa-safari-identity" "expected $SAFARI_SIGNING_ID, found ${signing_id:-no live Safari identity}"
    SANTA_HEALTHY=0
  fi

  if [ "$SANTA_ENFORCE_SAFARI" != 1 ]; then
    audit_skip "santa-profile" "Safari enforcement rollout gate is disabled"
    audit_skip "santa-safari-rule" "Safari enforcement rollout gate is disabled"
    audit_skip "safari-process" "Safari enforcement rollout gate is disabled"
    return
  fi

  canonical="$EXPECTED/com.chickenblocker.santa.mobileconfig"
  if [ ! -f "$canonical" ]; then
    SANTA_PROFILE_STATE="canonical-missing"
    audit_fail "santa-profile" "canonical production profile is missing: $canonical"
  elif ! command -v python3 >/dev/null 2>&1; then
    SANTA_PROFILE_STATE="unreadable"
    audit_fail "santa-profile" "python3 is required to compare the installed profile"
  else
    SANTA_PROFILE_STATE="$(profile_state "$canonical")"
    expected_count="$(python3 -c 'import plistlib,sys; print(len(plistlib.load(open(sys.argv[1],"rb"))["PayloadContent"][0]["StaticRules"]))' "$canonical" 2>/dev/null || true)"
    if [ "$SANTA_PROFILE_STATE" = ok ] && [ "$SANTA_STATIC_COUNT" = "$expected_count" ]; then
      audit_pass "santa-profile" "canonical system profile is installed with $expected_count effective static rule(s)"
    elif [ "$SANTA_PROFILE_STATE" = absent ]; then
      audit_fail "santa-profile" "profile is absent; local rule fallback is temporary only"
    else
      audit_fail "santa-profile" "installed/effective StaticRules differ from the canonical profile ($SANTA_PROFILE_STATE, count=${SANTA_STATIC_COUNT:-unknown})"
    fi
  fi

  rule=""
  if [ -n "$SAFARI_EXE" ] && [ -n "$SANTACTL" ]; then
    rule="$("$SANTACTL" fileinfo --key Rule "$SAFARI_EXE" 2>/dev/null || true)"
  fi
  case "$rule" in
    "Blocked (SigningID"*) audit_pass "santa-safari-rule" "$rule" ;;
    *) audit_fail "santa-safari-rule" "live Safari executable is not blocked by a SigningID rule (${rule:-no decision})" ;;
  esac

  SAFARI_PIDS="$(pgrep -x Safari 2>/dev/null || true)"
  if [ -z "$SAFARI_PIDS" ]; then
    audit_pass "safari-process" "no main Safari process is running"
  else
    audit_fail "safari-process" "main Safari PID(s) running: $(printf '%s' "$SAFARI_PIDS" | tr '\n' ' ')"
  fi
}

repair_santa_fallback() {
  [ "$SANTA_CHECKS" = 1 ] && [ "$SANTA_ENFORCE_SAFARI" = 1 ] || return
  [ "$SANTA_LOCAL_RULE_FALLBACK" = 1 ] || return
  [ "$SANTA_HEALTHY" = 1 ] || return
  [ "$SANTA_PROFILE_STATE" = absent ] || return
  [ "$SANTA_STATIC_COUNT" = 0 ] || {
    warn_limited "santa-profile" "static rules are active without the canonical profile; refusing local database changes"
    return
  }
  [ -n "${SANTACTL:-}" ] && [ -n "$SAFARI_EXE" ] || return
  current="$("$SANTACTL" fileinfo --key Rule "$SAFARI_EXE" 2>/dev/null || true)"
  case "$current" in "Blocked (SigningID"*) return ;; esac

  now="$(date +%s)"
  last="$(cat "$BASE/.santa-repair-last" 2>/dev/null || echo 0)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now - last)) -lt "$SANTA_REPAIR_MIN_INTERVAL" ]; then return; fi
  echo "$now" > "$BASE/.santa-repair-last" 2>/dev/null || true
  if "$SANTACTL" rule --block --signingid --identifier "$SAFARI_SIGNING_ID" \
      --message "Safari is disabled by ChickenBlocker. Use managed Firefox." >/dev/null 2>&1; then
    REPAIRED=$((REPAIRED+1))
    log "REPAIRED santa-safari-rule: added temporary local SigningID fallback"
  else
    FAIL=$((FAIL+1))
    log "REPAIR-FAILED santa-safari-rule: local rule management unavailable; reinstall the canonical profile manually"
  fi
}

terminate_verified_safari() {
  [ "$SANTA_CHECKS" = 1 ] && [ "$SANTA_ENFORCE_SAFARI" = 1 ] || return
  [ -n "$SAFARI_PIDS" ] && [ -n "${SANTACTL:-}" ] || return
  verified=""
  for pid in $SAFARI_PIDS; do
    path="$(pid_executable "$pid" 2>/dev/null || true)"
    identity=""
    [ -n "$path" ] && identity="$("$SANTACTL" fileinfo --key 'Signing ID' "$path" 2>/dev/null || true)"
    if [ "$identity" = "$SAFARI_SIGNING_ID" ]; then
      verified="$verified $pid"
    else
      warn_limited "safari-process" "refusing to terminate PID $pid because its executable identity is ${identity:-unresolved}"
    fi
  done
  [ -n "$verified" ] || return

  now="$(date +%s)"
  last="$(cat "$BASE/.safari-repair-last" 2>/dev/null || echo 0)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now - last)) -lt "$SANTA_REPAIR_MIN_INTERVAL" ]; then return; fi
  echo "$now" > "$BASE/.safari-repair-last" 2>/dev/null || true

  for pid in $verified; do
    kill -0 "$pid" 2>/dev/null || continue
    osascript -l JavaScript -e \
      "ObjC.import('AppKit'); var app = $.NSRunningApplication.runningApplicationWithProcessIdentifier($pid); if (app) { app.terminate; }" \
      >/dev/null 2>&1 || true
  done
  sleep 3
  for pid in $verified; do
    kill -0 "$pid" 2>/dev/null || continue
    path="$(pid_executable "$pid" 2>/dev/null || true)"
    identity=""
    [ -n "$path" ] && identity="$("$SANTACTL" fileinfo --key 'Signing ID' "$path" 2>/dev/null || true)"
    [ "$identity" = "$SAFARI_SIGNING_ID" ] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 2
  for pid in $verified; do
    kill -0 "$pid" 2>/dev/null || continue
    path="$(pid_executable "$pid" 2>/dev/null || true)"
    identity=""
    [ -n "$path" ] && identity="$("$SANTACTL" fileinfo --key 'Signing ID' "$path" 2>/dev/null || true)"
    [ "$identity" = "$SAFARI_SIGNING_ID" ] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done
  REPAIRED=$((REPAIRED+1))
  log "REPAIRED safari-process: quit identity-verified main Safari process(es)"
}

ext_py() {
cat <<'PY'
import json, os, sys
mode, prof = sys.argv[1], sys.argv[2]
ids = sys.argv[3:]
path = os.path.join(prof, "extensions.json")
try:
    with open(path, "r") as f:
        data = json.load(f)
except Exception:
    print("UNREADABLE"); sys.exit(2)
addons = data.get("addons")
if not isinstance(addons, list):
    print("UNREADABLE"); sys.exit(2)

def find(aid):
    for a in addons:
        if isinstance(a, dict) and a.get("id") == aid:
            return a
    return None

if mode == "check":
    bad = []
    for aid in ids:
        e = find(aid)
        if e is None:
            bad.append(aid.split("@")[0] + ":missing")
        elif e.get("active") is not True or e.get("userDisabled") is not False:
            bad.append(aid.split("@")[0] + ":inactive")
    if bad:
        print(" ".join(bad)); sys.exit(1)
    print("OK"); sys.exit(0)

changed = []
for aid in ids:
    e = find(aid)
    if e is None:
        changed.append(aid.split("@")[0] + ":missing(install-on-restart)")
    elif e.get("active") is not True or e.get("userDisabled") is not False:
        e["active"] = True
        e["userDisabled"] = False
        changed.append(aid.split("@")[0] + ":re-enabled")
if changed:
    tmp = path + ".cbtmp"
    with open(tmp, "w") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
    os.rename(tmp, path)
if changed:
    print(",".join(changed))
PY
}

ext_ids() {
  ids="$LB_ID"
  [ -f "$BASE/extensions/page_keyword_filter.xpi" ] && ids="$ids $PKF_ID"
  printf '%s' "$ids"
}

# check_extension_state: audit all profiles; daemon/repair mode records drift
# profiles in EXT_DRIFT_PROFILES (newline-separated). Requires Full Disk
# Access for /bin/bash (System Settings -> Privacy & Security): the launchd
# daemon context is TCC-blocked from Firefox's profile container even as
# root, and "responsible process" attribution covers asuser/sudo children,
# so only the FDA grant lets the daemon read browser data.
check_extension_state() {
  if [ "$(id -u)" != 0 ]; then
    SKIP=$((SKIP+1))
    [ "$MODE" = check ] && echo "  [SKIP] extension-state — needs root (sudo)"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    SKIP=$((SKIP+1))
    [ "$MODE" = check ] && echo "  [SKIP] extension-state — python3 not available on this Mac"
    return
  fi
  if [ ! -f "$EXPECTED/leechblockng-managed-storage.json" ]; then
    SKIP=$((SKIP+1))
    [ "$MODE" = check ] && echo "  [SKIP] extension-state — rules not synced yet"
    return
  fi
  ids="$(ext_ids)"
  found=0
  for prof in /Users/*/Library/Application\ Support/Firefox/Profiles/*/; do
    [ -f "$prof/extensions.json" ] || continue
    found=1
    name="$(basename "$prof")"
    out="$(ext_py | python3 - check "$prof" $ids 2>"$BASE/.ext-err")"
    rc=$?
    if [ "$rc" = 0 ]; then
      PASS=$((PASS+1))
      [ "$MODE" = check ] && echo "  [PASS] extension-state[$name] — extensions active"
    elif [ "$rc" = 1 ]; then
      if [ "$MODE" = check ]; then
        FAIL=$((FAIL+1))
        echo "  [FAIL] extension-state[$name] — $out"
      else
        EXT_DRIFT_PROFILES="${EXT_DRIFT_PROFILES}${prof}
"
        log "EXTENSION-DRIFT $name: $out"
      fi
    else
      SKIP=$((SKIP+1))
      if [ "$MODE" = check ]; then
        echo "  [SKIP] extension-state[$name] — extensions.json unreadable ($(head -1 "$BASE/.ext-err" 2>/dev/null))"
      else
        log "EXTENSION-CHECK-ERROR $name rc=$rc: $(head -1 "$BASE/.ext-err" 2>/dev/null)"
      fi
    fi
  done
  if [ "$found" = 0 ]; then
    SKIP=$((SKIP+1))
    if [ "$MODE" = check ]; then
      echo "  [SKIP] extension-state — no Firefox profiles readable (grant Full Disk Access to the verifier interpreter (BASE/bin/cb-bash))"
    else
      log "EXTENSION-CHECK-ERROR no profile readable as root — grant Full Disk Access to the verifier interpreter (BASE/bin/cb-bash)"
    fi
  fi
}

# repair_profile <dir>: re-enable drifted extensions while Firefox is quit,
# then drop the addonStartup cache. Runs as root (needs the same FDA grant);
# restores owner and mode.
repair_profile() {
  prof="$1"
  ids="$(ext_ids)"
  ext="$prof/extensions.json"
  [ -f "$ext" ] || return
  own="$(stat -f '%u:%g' "$ext" 2>/dev/null || true)"
  mod="$(stat -f '%Lp' "$ext" 2>/dev/null || echo 644)"
  out="$(ext_py | python3 - repair "$prof" $ids 2>/dev/null)"
  if [ -n "$out" ]; then
    [ -n "$own" ] && chown "$own" "$ext" 2>/dev/null
    chmod "$mod" "$ext" 2>/dev/null
    rm -f "$prof/addonStartup.json.lz4" "$prof/addonStartup.json" 2>/dev/null
    log "REPAIRED extensions.json in $prof: $out (startup cache dropped)"
  fi
}

resolve_console_user() {
  CONSOLE_USER=""
  CONSOLE_UID="$(stat -f %u /dev/console 2>/dev/null || true)"
  if [ -n "$CONSOLE_UID" ] && [ "$CONSOLE_UID" != 0 ]; then
    CONSOLE_USER="$(id -nu "$CONSOLE_UID" 2>/dev/null || true)"
  fi
}

firefox_running() { pgrep -x firefox >/dev/null 2>&1; }

quit_firefox() {
  resolve_console_user
  if [ -n "$CONSOLE_USER" ]; then
    launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" \
      osascript -e 'tell application "Firefox" to quit' >/dev/null 2>&1 || true
  fi
  i=0
  while [ "$i" -lt 10 ] && firefox_running; do
    sleep 1
    i=$((i+1))
  done
  pkill -x firefox 2>/dev/null || true
  sleep 1
}

relaunch_firefox() {
  resolve_console_user
  if [ -n "$CONSOLE_USER" ]; then
    launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" \
      open -a Firefox >/dev/null 2>&1 || true
    log "Firefox relaunched"
  else
    log "Firefox relaunch skipped (no GUI console user)"
  fi
}

# do_check <label> <expected-src> <live-dst> <managed-flag> [owner] [restart-flag]
# Sets global counters; check mode reports, daemon/repair mode repairs.
# owner defaults to root:wheel; the Firefox policies file is owned like the
# app bundle itself so Firefox's updater does not fall back to elevated
# (admin password) updates.
do_check() {
  label="$1"
  src="$2"
  dst="$3"
  managed="$4"
  owner="${5:-root:wheel}"
  restart="${6:-0}"

  if [ ! -f "$src" ]; then
    SKIP=$((SKIP+1))
    [ "$MODE" = check ] && echo "  [SKIP] $label — expected file not present: $src"
    return
  fi

  problem=""
  if [ ! -f "$dst" ]; then
    problem="missing"
  elif ! cmp -s "$src" "$dst"; then
    problem="content drift"
  elif [ "$(stat -f '%Su:%Sg' "$dst" 2>/dev/null)" != "$owner" ] ||
       [ "$(stat -f '%Lp' "$dst" 2>/dev/null)" != "644" ]; then
    problem="owner/mode"
  fi

  if [ -z "$problem" ]; then
    PASS=$((PASS+1))
    [ "$MODE" = check ] && echo "  [PASS] $label — $dst"
    return
  fi

  if [ "$MODE" = check ]; then
    FAIL=$((FAIL+1))
    echo "  [FAIL] $label — $problem: $dst"
    return
  fi

  mkdir -p "$(dirname "$dst")"
  if cp "$src" "$dst.cb-new" && chmod 0644 "$dst.cb-new" &&
     chown "$owner" "$dst.cb-new" && mv "$dst.cb-new" "$dst"; then
    REPAIRED=$((REPAIRED+1))
    [ "$managed" = 1 ] && REPAIRED_MANAGED=1
    [ "$restart" = 1 ] && REPAIRED_RESTART=1
    log "REPAIRED $label ($problem): $dst"
  else
    rm -f "$dst.cb-new"
    FAIL=$((FAIL+1))
    log "REPAIR-FAILED $label ($problem): $dst"
  fi
}

check_profile_stylesheets() {
  if [ ! -f "$EXPECTED/userChrome.css" ] || [ ! -f "$EXPECTED/userContent.css" ]; then
    SKIP=$((SKIP+1))
    [ "$MODE" = check ] && echo "  [SKIP] profile-stylesheets — run sync-to-mac.sh"
    return
  fi
  found=0
  for prof in /Users/*/Library/Application\ Support/Firefox/Profiles/*/; do
    [ -d "$prof" ] || continue
    found=1
    owner="$(stat -f '%Su:%Sg' "$prof" 2>/dev/null || echo root:wheel)"
    if [ "$MODE" != check ] && [ ! -d "$prof/chrome" ]; then
      mkdir -p "$prof/chrome"
      chown "$owner" "$prof/chrome" 2>/dev/null || true
    fi
    name="$(basename "$prof")"
    do_check "userChrome[$name]" "$EXPECTED/userChrome.css" \
      "$prof/chrome/userChrome.css" 0 "$owner" 1
    do_check "userContent[$name]" "$EXPECTED/userContent.css" \
      "$prof/chrome/userContent.css" 0 "$owner" 1
  done
  if [ "$found" = 0 ]; then
    SKIP=$((SKIP+1))
    [ "$MODE" = check ] && echo "  [SKIP] profile-stylesheets — no Firefox profiles found"
  fi
}

record_firefox_profile_state() {
  state="$1"
  [ "$MODE" != check ] && [ "$(id -u)" = 0 ] || return
  marker="$BASE/.firefox-profile-state"
  previous="$(cat "$marker" 2>/dev/null || true)"
  if [ -n "$previous" ] && [ "$previous" != "$state" ]; then
    case "$state" in
      active:*)
        FIREFOX_POLICY_RESTART=1
        log "Firefox policy became active or changed — scheduling controlled Firefox restart"
        ;;
    esac
  fi
  if [ "$previous" != "$state" ]; then
    printf '%s\n' "$state" > "$marker.cb-new" 2>/dev/null &&
      chmod 0600 "$marker.cb-new" 2>/dev/null &&
      mv "$marker.cb-new" "$marker" 2>/dev/null || true
  fi
}

# check_firefox_policy_channel: Firefox policies arrive via the
# locally-installed user configuration profile (com.chickenblocker.firefox,
# managed org.mozilla.firefox preferences). A bare file dropped into
# /Library/Managed Preferences is NOT honored by Firefox, and macOS 27 has
# no CLI to (re)install profiles — so this is check-only. Verify both profile
# presence and materialized sentinel values; checking only the identifier can
# falsely accept an obsolete system-scoped or incomplete profile.
check_firefox_policy_channel() {
  if [ "$(id -u)" != 0 ]; then
    SKIP=$((SKIP+1))
    [ "$MODE" = check ] && echo "  [SKIP] firefox-profile — needs root (sudo)"
    return
  fi
  resolve_console_user
  problem=""
  if [ -z "$CONSOLE_USER" ]; then
    problem="no GUI console user"
  elif ! profiles show -type configuration -user "$CONSOLE_USER" 2>/dev/null | grep -q "com.chickenblocker.firefox"; then
    problem="not installed for $CONSOLE_USER"
  else
    prefs="/Library/Managed Preferences/$CONSOLE_USER/org.mozilla.firefox.plist"
    if [ ! -f "$prefs" ]; then
      problem="managed preferences not materialized for $CONSOLE_USER"
    elif [ "$(plutil -extract EnterprisePoliciesEnabled raw -o - "$prefs" 2>/dev/null || true)" != true ]; then
      problem="EnterprisePoliciesEnabled is not true (reinstall the current profile)"
    elif [ "$(plutil -extract DisablePrivateBrowsing raw -o - "$prefs" 2>/dev/null || true)" != true ]; then
      problem="DisablePrivateBrowsing is not true (reinstall the current profile)"
    fi
  fi
  if [ -z "$problem" ]; then
    FIREFOX_POLICY_HEALTHY=1
    fingerprint="$(cksum < "$prefs" 2>/dev/null || true)"
    record_firefox_profile_state "active:$fingerprint"
    PASS=$((PASS+1))
    [ "$MODE" = check ] && echo "  [PASS] firefox-profile — installed and active for $CONSOLE_USER"
    return
  fi
  record_firefox_profile_state inactive
  if [ "$MODE" = check ]; then
    FAIL=$((FAIL+1))
    echo "  [FAIL] firefox-profile — $problem (System Settings: install $EXPECTED/org.mozilla.firefox.mobileconfig)"
    return
  fi
  now="$(date +%s)"
  last="$(cat "$BASE/.profile-warn-last" 2>/dev/null || echo 0)"
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now - last)) -ge 3600 ]; then
    echo "$now" > "$BASE/.profile-warn-last" 2>/dev/null || true
    log "WARN firefox-profile inactive: $problem — install $EXPECTED/org.mozilla.firefox.mobileconfig via System Settings"
  fi
}

run_pass() {
  PASS=0; FAIL=0; SKIP=0; REPAIRED=0; REPAIRED_MANAGED=0; REPAIRED_RESTART=0
  FIREFOX_POLICY_RESTART=0; FIREFOX_POLICY_HEALTHY=0; EXT_DRIFT_PROFILES=""
  SANTA_PROFILE_STATE="unchecked"; SANTA_STATIC_COUNT=""; SANTA_HEALTHY=0; SAFARI_EXE=""; SAFARI_PIDS=""

  check_firefox_policy_channel

  do_check "leechblock-managed-storage" \
    "$EXPECTED/leechblockng-managed-storage.json" \
    "$MS_DIR/$LB_ID.json" 1

  do_check "pkf-managed-storage" \
    "$EXPECTED/pkf-managed-storage.json" \
    "$MS_DIR/$PKF_ID.json" 1

  do_check "pkf-extension" \
    "$EXPECTED/extensions/page_keyword_filter.xpi" \
    "/usr/local/lib/ChickenBlocker/page_keyword_filter.xpi" 0

  do_check "pkf-extension-legacy" \
    "$EXPECTED/extensions/page_keyword_filter.xpi" \
    "$BASE/extensions/page_keyword_filter.xpi" 0

  check_extension_state
  check_profile_stylesheets
  check_santa

  if [ "$MODE" = check ]; then
    if [ -f "$PLIST" ]; then
      PASS=$((PASS+1)); echo "  [PASS] LaunchDaemon plist — $PLIST"
    else
      FAIL=$((FAIL+1)); echo "  [FAIL] LaunchDaemon plist — $PLIST missing"
    fi
    if [ "$(id -u)" = 0 ]; then
      if launchctl print system/com.chickenblocker.verifier >/dev/null 2>&1; then
        PASS=$((PASS+1)); echo "  [PASS] LaunchDaemon loaded"
      else
        FAIL=$((FAIL+1)); echo "  [FAIL] LaunchDaemon not loaded"
      fi
    else
      SKIP=$((SKIP+1)); echo "  [SKIP] LaunchDaemon state — needs root (sudo)"
    fi
  fi
}

# recovery: act on drift found by run_pass (daemon/repair modes only).
# Extension drift is always enforced; managed-storage restart honours
# RESTART_FIREFOX_ON_REPAIR. Firefox is only relaunched if it was running
# when the pass started.
recovery() {
  was_running=0
  firefox_running && was_running=1
  killed=0

  # Flush preference caches so a repaired managed-prefs file is re-read.
  if [ "$REPAIRED" -gt 0 ]; then
    killall cfprefsd 2>/dev/null || true
  fi

  repair_santa_fallback
  terminate_verified_safari

  policy_blocked=0
  if [ "$FIREFOX_POLICY_HEALTHY" != 1 ]; then
    policy_blocked=1
    if firefox_running; then
      log "Firefox policy inactive — quitting Firefox (fail closed)"
      quit_firefox
      killed=1
    fi
  fi

  if [ -n "$EXT_DRIFT_PROFILES" ]; then
    if [ "$was_running" != 1 ]; then
      while IFS= read -r prof; do
        [ -n "$prof" ] || continue
        repair_profile "$prof"
      done <<< "$EXT_DRIFT_PROFILES"
    else
      now="$(date +%s)"
      last="$(cat "$BASE/.ext-restart-last" 2>/dev/null || echo 0)"
      case "$now" in ''|*[!0-9]*) now=0 ;; esac
      case "$last" in ''|*[!0-9]*) last=0 ;; esac
      if [ $((now - last)) -ge "$EXT_RESTART_MIN_INTERVAL" ]; then
        echo "$now" > "$BASE/.ext-restart-last" 2>/dev/null || true
        log "extension drift — quitting Firefox for extensions.json repair"
        quit_firefox
        killed=1
        while IFS= read -r prof; do
          [ -n "$prof" ] || continue
          repair_profile "$prof"
        done <<< "$EXT_DRIFT_PROFILES"
      else
        log "extension drift persists — restart suppressed (rate limit ${EXT_RESTART_MIN_INTERVAL}s); install may be failing"
      fi
    fi
  fi

  want_managed_restart=0
  { [ "$REPAIRED_MANAGED" = 1 ] || [ "$REPAIRED_RESTART" = 1 ]; } &&
    [ "$RESTART_FIREFOX_ON_REPAIR" = 1 ] && want_managed_restart=1
  [ "$FIREFOX_POLICY_RESTART" = 1 ] && want_managed_restart=1

  if [ "$want_managed_restart" = 1 ] || [ "$killed" = 1 ]; then
    if [ "$policy_blocked" = 1 ]; then
      log "Firefox remains closed until the managed policy is active"
    elif [ "$was_running" = 1 ]; then
      if firefox_running; then
        log "Firefox state repaired while running — controlled restart"
        quit_firefox
        killed=1
      fi
      if ! firefox_running; then
        relaunch_firefox
      fi
    else
      log "drift repaired while Firefox not running — not launching it"
    fi
  fi
}

case "$MODE" in
  daemon)
    sleep_pid=""
    trap 'log "verifier stopped"; [ -n "$sleep_pid" ] && kill "$sleep_pid" 2>/dev/null; exit 0' INT TERM
    log "verifier started (pid $$, interval ${CHECK_INTERVAL}s)"
    log "diag: python3=$(command -v python3 2>/dev/null || echo MISSING) console=$(stat -f %Su /dev/console 2>/dev/null || echo ?) ids=[$(ext_ids 2>/dev/null)]"
    while :; do
      run_pass
      recovery
      sleep "$CHECK_INTERVAL" &
      sleep_pid=$!
      wait $!
      sleep_pid=""
    done
    ;;
  repair)
    run_pass
    recovery
    echo "repaired=$REPAIRED failed=$FAIL skipped=$SKIP passed=$PASS"
    [ "$FAIL" = 0 ]
    ;;
  check)
    echo "=== ChickenBlocker-OSX verify ==="
    run_pass
    echo
    echo "=== RESULT: $PASS passed, $FAIL failed, $SKIP skipped ==="
    [ "$FAIL" = 0 ]
    ;;
esac
