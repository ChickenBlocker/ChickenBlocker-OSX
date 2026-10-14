# ChickenBlocker-OSX

macOS counterpart of [ChickenBlocker](../ChickenBlocker) (Linux). Phase 1 is a
root **LaunchDaemon that checks and re-asserts the Firefox policy channel and
the LeechBlock / Page Keyword Filter blocking rules**. Phase 2 adds staged
North Pole Security Santa tooling for an explicit Safari SigningID block rule.
See `../ChickenBlocker/.kilo/plans/osx_phase1.md` and
`../ChickenBlocker/.kilo/plans/osx_phase2_santa.md` for the design and rollout
gates.

Phase 2 is deployed on the target macOS 27.0.1 Mac: Santa 2026.8.244 activation,
local and static probe gates, profile rollback, the production Safari rule, and
the 21-check verifier audit pass. The full post-reboot Safari launch-vector and
unrelated-WebKit application matrix remains to be recorded before declaring the
entire acceptance plan complete. Fresh installs keep Safari enforcement off by
default.

## What it enforces

| Channel                                                       | Live target on the Mac |
| ------------------------------------------------------------- | ---------------------- |
| Firefox policies — user configuration profile `com.chickenblocker.firefox` (managed `org.mozilla.firefox` preferences) | User profile; verifier checks presence and materialized policy sentinels every cycle |
| LeechBlock settings — managed-storage manifest                | `/Library/Application Support/Mozilla/ManagedStorage/leechblockng@proginosko.com.json` |
| PKF keyword list — managed-storage manifest                   | `/Library/Application Support/Mozilla/ManagedStorage/page-keyword-filter-7f3a@local.addons.json` |
| PKF extension `.xpi` (signed copy pushed from Linux; space-free `file://` URL) | `/usr/local/lib/ChickenBlocker/page_keyword_filter.xpi` (+ legacy copy under `BASE/extensions/`) |
| Extension state — LeechBlock/PKF present and active in every Firefox profile | `<profile>/extensions.json`, repaired in place + `addonStartup` cache drop + controlled Firefox restart |
| Firefox UI/content stylesheets synced from Linux | `<profile>/chrome/userChrome.css` and `userContent.css`; repaired for normal profiles |
| Santa package, extension, mode, profile, Safari identity/rule/process state | Audited when `SANTA_CHECKS=1`; Safari is denied only when `SANTA_ENFORCE_SAFARI=1` |

`BASE` is `/Library/Application Support/ChickenBlocker`.

The Firefox policies block `about:addons`/`about:profiles`, private browsing
and developer tools, force-install **LeechBlock NG** (anonymous AMO
direct-download link — no account) and the **Page Keyword Filter** extension
(local `file://` xpi — nothing is downloaded from AMO), and lock both against
removal/disabling. The LeechBlock settings arrive as a managed-storage
manifest, snapshotted from the Linux machine's Firefox. Rule content is copied,
but every populated set is deliberately forced active seven days a week from
`0000-2359`, with no time allowance or disabled flag. Thus the Mac blocks all
sites/regex rules present in the Linux sets even when their Linux schedules or
active toggles would currently allow access. Empty sets remain inactive.

The profile uses Mozilla's required macOS format:
`com.apple.ManagedClient.preferences`, `mcx_preference_settings`, and
`EnterprisePoliciesEnabled=true`. This exact schema was verified on the target
Mac: it materializes at `/Library/Managed Preferences/<user>/org.mozilla.firefox.plist`
and appears as Active in `about:policies`.

Both managed extensions also set `ExtensionSettings.<id>.private_browsing=true`
(Firefox 136+ / ESR 128.8+). Private browsing itself remains disabled, so this
is defense in depth if a private window is already open or that policy changes.
Using policy is preferred over editing Firefox's generated `extensions.json`.

Direct LeechBlock options URLs are a separate surface from `about:addons`.
`WebsiteFilter` blocks `moz-extension://*/options.html*` application-wide, so
the rule works across profile-specific extension UUIDs and arbitrary Firefox
profiles. `userChrome.css` additionally hides the LeechBlock toolbar action in
normal profiles. The stylesheet preference is enabled and locked by policy;
CSS is only a UI layer, while `WebsiteFilter` is the actual navigation block.

Extension-state enforcement is a port of the Linux ChickenBlocker daemon:
if a profile's `extensions.json` shows LeechBlock or PKF disabled or
missing, Firefox is quit, the entry is re-enabled in place, the startup
cache is dropped, and Firefox is relaunched — but only if it was already
running, and at most once per `EXT_RESTART_MIN_INTERVAL` (300 s) so a
failing install cannot loop.

## Layout

```text
ChickenBlocker-OSX/
  config/firefox-policies.json        canonical macOS Firefox policies
  config/santa-release.json           pinned Santa package provenance
  config/santa-rules.json             reviewed production static rules
  daemon/cb-verifier.sh               check & repair service (bash)
  daemon/com.chickenblocker.verifier.plist
  tools/gen-firefox-profile.py        generates the .mobileconfig (and plist)
  tools/gen-santa-profile.py          deterministic production/probe/rollback profiles
  tools/fetch-santa.sh                downloads and verifies the pinned official PKG
  tools/santa-probe.c                 no-side-effect disposable execution probe
  sync/extract_rules.py               Linux side: snapshot rules to staged/
  sync/sync-to-mac.sh                 Linux side: push staged/ to the Mac
  install.sh / uninstall.sh           Phase 1 local or over-SSH install
  install-santa.sh                    explicit Phase 2 staging commands
```

## Install (fresh Mac)

```sh
# 1. install daemon + files (from Linux: over SSH; SSH is used only when a
#    target is given)
./install.sh user@mac-host

# 2. on the Mac: grant Full Disk Access to the verifier's private interpreter
#    (NOT /bin/bash):
#    System Settings -> Privacy & Security -> Full Disk Access -> +
#    Cmd+Shift+G -> /Library/Application Support/ChickenBlocker/bin/cb-bash
ssh -t user@mac-host 'sudo launchctl kickstart -k system/com.chickenblocker.verifier'

# 3. one-time Firefox profile install on the Mac (macOS 27 has no CLI for it):
#    Finder -> Cmd+Shift+G -> /Library/Application Support/ChickenBlocker/expected
#    double-click org.mozilla.firefox.mobileconfig, then
#    System Settings -> General -> Device Management -> double-click the
#    downloaded profile -> Install -> Install (admin password)

# 4. push the rules from the Linux machine
sync/sync-to-mac.sh user@mac-host
```

Step 2 is required because macOS TCC blocks even root LaunchDaemons from
reading browser profile data (`extensions.json`); the grant is scoped to the
ad-hoc-signed `cb-bash` copy so no other shell gains anything. Step 3 is
required because macOS 27 removed `profiles install`; the profile survives
Firefox updates and only changes when `config/firefox-policies.json` does.

## Sync rules from the Linux machine

Run on the Linux machine that has this repo checked out next to the
`ChickenBlocker` repo (or set `CB_LINUX_REPO`):

```sh
sync/sync-to-mac.sh user@mac-host    # extract + push + repair + audit
sync/sync-to-mac.sh                  # extract only, into ./staged (gitignored)
```

Extraction snapshots: LeechBlock settings (from Firefox's
`storage-sync-v2.sqlite`), the live PKF keyword manifest, the signed `.xpi`,
and the Linux repository's `userChrome.css`/`userContent.css`. Keyword words
are printed as counts only and are never committed. The LeechBlock snapshot
normalizes every populated set to always-blocked before it is staged; sync is
still an explicit push and does not continuously poll the Linux machine.

## Verifier

```sh
sudo bash "$BASE/verifier.sh" check    # one-shot audit (exit 1 on FAIL)
sudo bash "$BASE/verifier.sh" repair   # one repair pass
sudo bash "$BASE/verifier.sh" daemon   # loop (what the LaunchDaemon runs)
```

Checks run every `CHECK_INTERVAL` seconds (default 15). Missing, drifting,
or mis-permissioned files are reinstalled from the canonical copies and
logged to `BASE/verifier.log`. A missing configuration profile is warned
about hourly (it cannot be reinstalled headless). Config:
`BASE/verifier.conf` (`CHECK_INTERVAL`, `RESTART_FIREFOX_ON_REPAIR`,
`EXT_RESTART_MIN_INTERVAL`, `SANTA_CHECKS`, `SANTA_ENFORCE_SAFARI`,
`SANTA_LOCAL_RULE_FALLBACK`, `SANTA_REINSTALL`). Ordinary Phase 1 reinstalls
preserve existing values and only append missing safe defaults.

## Phase 2: Santa and Safari

The pinned package is the standard official North Pole Security Santa 2026.8
PKG from `https://github.com/northpolesec/santa/releases/tag/2026.8`:

```text
filename: santa-2026.8.pkg
SHA-256: 0aaa970c7ddc63fe6a55c3144c825acb7f6bfa9cb15bcba1bffcaf2b5efc952a
receipt version: 2026.8.244
Team ID: ZMCG7MLDV9
receipt: com.northpolesec.santa
system extension: com.northpolesec.santa.daemon
```

The fetcher rejects a different filename, checksum, untrusted installer chain,
or Team ID. It never executes the PKG and has no `latest`, mirror, Homebrew, or
unchecked fallback. A version update requires a reviewed metadata change,
release-note and advisory review, a new checksum, and repetition of every probe
and Safari acceptance gate.

Santa stays in **Monitor mode** (`ClientMode=1`). Monitor mode permits unrelated
binaries; the explicit `BLOCKLIST` rule for
`platform:com.apple.Safari` denies Safari. Safari is not removed or modified.
There is no Santa sync server, MDM enrollment, network extension, Lockdown mode,
path rule, file-access rule, or WebKit helper rule in this phase.

### Package and activation gate

Run on the Mac, or add `user@mac-host` after a stage to use the unprivileged
transport. Remote transport leaves files under `/tmp`, preserves the remotely
downloaded PKG between stages, and prints privileged commands rather than
invoking remote `sudo` itself.

```sh
tools/fetch-santa.sh
./install-santa.sh preflight
./install-santa.sh install-package
# Review and run the exact sudo command printed by install-package.
```

From the Linux machine, the equivalent remote sequence is:

```sh
./install-santa.sh fetch user@mac-host
./install-santa.sh preflight user@mac-host
./install-santa.sh install-package user@mac-host
# Review and run the printed ssh -t ... sudo ... command.
```

After package installation, manually enable:

1. Run `./install-santa.sh request-extension-approval` locally or `./install-santa.sh request-extension-approval user@mac-host` remotely. This repeats Santa's supported `--load-system-extension` request and opens the settings parent pane.
2. In the Extensions section, switch the selector from **By App** to **By Category**. Endpoint Security Extensions is hidden from the By App view on the tested macOS 27 build.
3. Click the circled information icon at the right of **Endpoint Security Extensions**. In the popup that opens, enable Santa and click **Done**.
4. Alternatively, check for a macOS approval notification or a blocked Santa system-software banner under Privacy & Security.
5. If the category and approval banner are both absent, stop at this gate rather than installing the production rule profile.
6. System Settings -> Privacy & Security -> Full Disk Access -> `com.northpolesec.santa.daemon`, plus only components specifically requested by `santactl doctor`.

System-extension approval and Full Disk Access are separate. Granting FDA does
not resolve an `[activated waiting for user]` extension state. System Settings
search for `Extensions` can also reveal the relocated pane on macOS builds that
do not show the documented category directly.

Do not enable the optional Santa network extension. Confirm activation before
continuing:

```sh
systemextensionsctl list com.apple.system_extension.endpoint_security
santactl version
santactl status
sudo santactl doctor
```

The system extension must be `activated enabled`, the release must be 2026.8
with receipt build `2026.8.244`, status must report Monitor, and doctor must
pass. Confirm Firefox, Terminal, SSH, compilers, and ordinary applications
still run. Stop if any check fails. The utility checks `/usr/local/bin` and the
bundled `/Applications/Santa.app/Contents/MacOS/santactl`, so a restricted SSH
`PATH` does not hide an installed CLI.

Santa 2026.8 has an upstream `santactl doctor` exit-status bug when sync is
disabled: its process check still returns failure for the intentionally absent
sync service even though it prints no `[-]` finding. The verifier therefore
requires successful `santactl status` daemon communication and rejects any
printed doctor `[-]` finding, rather than trusting that false nonzero status.

### Disposable local-rule gate

```sh
./install-santa.sh make-probe
```

The command embeds a per-build nonce, prints a unique
`/tmp/chickenblocker-santa-probe-*` path and Santa file information, prints
exact local-rule gate commands, and generates a profile for that exact SHA-256.
Before using the profile:

1. Run the probe successfully once.
2. Add a local BINARY block rule with `sudo santactl rule --block --identifier <printed-sha256>`.
3. Confirm a new execution is denied and the event identifies the exact hash.
4. Remove it with `sudo santactl rule --remove --identifier <printed-sha256>`.
5. Confirm the probe executes again.

Never substitute a shell, browser, Apple system binary, package manager, or
shared developer tool for the disposable probe.

### StaticRules and rollback gate

```sh
./install-santa.sh stage-profile
# Review and run the printed sudo staging command.
```

All generated files are linted with `plutil` on the Mac and staged under
`BASE/expected`. Install profiles manually on macOS 27: double-click the
`.mobileconfig`, then finish installation in System Settings -> General ->
Device Management. No script claims to install a profile.

The printed privileged staging command also deploys the Phase 2 verifier and
adds missing safe-default flags without overwriting existing values. After
running it, set `SANTA_CHECKS=1` in `BASE/verifier.conf`. Leave
`SANTA_ENFORCE_SAFARI=0` through all probe gates.

Display current values and the required transitions with:

```sh
./install-santa.sh show-config
./install-santa.sh show-config user@mac-host
```

The rollout values are:

```text
SANTA_CHECKS=0              package/extension/FDA activation incomplete
SANTA_CHECKS=1              extension activated enabled and doctor passes
SANTA_ENFORCE_SAFARI=0      all probe and rollback gates
SANTA_ENFORCE_SAFARI=1      production profile and live Safari rule verified
SANTA_LOCAL_RULE_FALLBACK=1 temporary exact-SigningID fallback enabled
SANTA_REINSTALL=0           automatic package reinstall disabled
```

Edit `BASE/verifier.conf` explicitly with `sudo nano`; ordinary installs and
staging preserve existing values.

1. Install `com.chickenblocker.santa.probe.mobileconfig` and confirm one static rule and a denied probe.
2. Confirm `santactl rule --remove` cannot remove the static probe rule.
3. Compile a different probe and confirm Monitor mode allows it.
4. Remove the probe profile through Device Management.
5. Install `com.chickenblocker.santa.rollback.mobileconfig` and confirm the original probe runs.

This is a hard compatibility gate. If a locally installed system-scoped custom
payload does not become effective forced configuration on macOS 27, do not
install the production profile. Use only the verified local SigningID fallback
and document the wider bypass window.

`PayloadRemovalDisallowed=true` adds local friction; it is not equivalent to a
non-removable MDM profile.

### Safari identity and rollout gate

Locate Safari by bundle ID and inspect the actual executable with `codesign`,
`lipo`, and `santactl fileinfo`. Its Santa Signing ID must be exactly
`platform:com.apple.Safari`. Inventory Safari Web Apps separately; do not add
their `com.apple.Safari.WebApp` identity automatically.

1. Test the rollback production profile once more.
2. Quit Safari completely.
3. Install `com.chickenblocker.santa.mobileconfig` manually.
4. Confirm `santactl status --json` reports one static rule.
5. Confirm `santactl fileinfo --key Rule <Safari-executable>` reports `Blocked (SigningID, Static)`.
6. Set `SANTA_ENFORCE_SAFARI=1` in `BASE/verifier.conf`.
7. Run `./install-santa.sh verify` and then the complete acceptance matrix in the Phase 2 plan.

The verifier never launches Safari. With enforcement enabled it checks the
pinned receipt, Santa.app Team ID, extension state, doctor/status, Monitor
mode, canonical profile and static-rule count, live Safari identity, rule
decision, and existing main Safari processes. If the profile is absent and
local rule management is available, repair mode can restore only the exact
Safari SigningID rule. A mismatched static profile is a hard failure requiring
manual canonical-profile replacement. Automatic package reinstall is disabled.

For profile auditing, the verifier compares the canonical payload against the
effective `/Library/Managed Preferences/com.northpolesec.santa.plist` domain,
including its payload UUID and an exact allowlist of effective keys. This avoids
macOS 27's inconsistent `profiles show` XML while still rejecting extra or
mismatched configuration.

If a main Safari process predates the rule, the verifier requests a normal quit
and then signals only PIDs whose live executable still resolves to the exact
Safari SigningID. It never kills generic `com.apple.WebKit.*` processes.

### Rule-only rollback

1. Set `SANTA_ENFORCE_SAFARI=0` first.
2. Install the rollback profile or manually remove the ChickenBlocker Santa profile in Device Management.
3. After confirming no non-empty `StaticRules` profile controls rules, remove a fallback with `sudo santactl rule --remove --signingid --identifier platform:com.apple.Safari`.
4. Confirm `santactl fileinfo` no longer reports Safari blocked.
5. Launch Safari once as the positive rollback test.

This leaves Santa installed in Monitor mode and is the preferred emergency
recovery. Full Santa uninstall is a separate explicit operation. First replace
or remove the ChickenBlocker profile and disable Santa verifier flags, then
review the pinned vendor procedure in `config/santa-uninstall-2026.8.txt`.
Never disable SIP, enable system-extension developer mode, reset system
extensions, or delete `/var/db/santa` for normal rollback.

## Uninstall

```sh
sudo ./uninstall.sh          # on the Mac (also removes the managed prefs file)
./uninstall.sh user@mac-host # from Linux over SSH
```

Also remove the profile manually (System Settings → General → Device
Management → −) and the FDA grant if desired; restart Firefox afterwards.
This is the Phase 1 uninstaller: it removes the ChickenBlocker verifier and
expected files but does not uninstall Santa or deactivate its system extension.

## Security posture (honest limits)

- This is the **friction layer** of the local track: an unrestricted local
  root session can `launchctl bootout` the daemon, remove the profile via
  System Settings, and edit ordinary files. Drift is closed within seconds
  (profile loss: hourly warning), but a minutes-long bypass window exists
  under root — exactly as documented in the plan's section 8.
- Santa blocks new Safari executions before useful browser code runs and is a
  stronger boundary than process killing, but Phase 2 remains friction-grade.
  The profile is locally installed, not MDM-owned. An unrestricted local
  administrator can remove it, stop the verifier, use vendor uninstall paths,
  or modify local rules when no non-empty `StaticRules` profile is active.
- Safari Web Apps have a distinct identity, and embedded WebViews use shared
  WebKit components. Phase 2 blocks neither automatically.
- Root-resistant MDM `DeniedBinaries` declarations and Recovery protections
  remain later work. Do not describe this implementation as root-resistant.
- The FDA grant covers only `BASE/bin/cb-bash` (deterministic ad-hoc
  signature; re-grant only if Apple updates `/bin/bash`).
