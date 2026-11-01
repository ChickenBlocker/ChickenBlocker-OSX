# ChickenBlocker-OSX

macOS counterpart of [ChickenBlocker](../ChickenBlocker) (Linux). Phase 1 is a
root **LaunchDaemon that checks and re-asserts the Firefox policy channel and
the LeechBlock / Page Keyword Filter blocking rules**. Phase 2 adds staged
North Pole Security Santa tooling for an explicit Safari SigningID block rule.

Phase 2 is deployed on the target macOS 27.0.1 Mac: Santa 2026.8.244 activation,
local and static probe gates, profile rollback, the production Safari rule, and
the verifier audit pass. The full post-reboot Safari launch-vector and
unrelated-WebKit application matrix remains to be recorded before declaring the
entire acceptance plan complete. Fresh installs keep Safari enforcement off by
default.

## What it enforces

| Channel                                                       | Live target on the Mac |
| ------------------------------------------------------------- | ---------------------- |
| Firefox policies — user configuration profile `com.chickenblocker.firefox` (managed `org.mozilla.firefox` preferences) | User profile; verifier checks presence and materialized policy sentinels every cycle and can reinstall through the guarded Accessibility helper |
| LeechBlock settings — managed-storage manifest                | `/Library/Application Support/Mozilla/ManagedStorage/leechblockng@proginosko.com.json` |
| PKF keyword list — managed-storage manifest                   | `/Library/Application Support/Mozilla/ManagedStorage/page-keyword-filter-7f3a@local.addons.json` |
| PKF extension `.xpi` (signed copy pushed from Linux; space-free `file://` URL) | `/usr/local/lib/ChickenBlocker/page_keyword_filter.xpi` (+ legacy copy under `BASE/extensions/`) |
| Extension state — LeechBlock/PKF present and active in every Firefox profile | `<profile>/extensions.json`, repaired in place + `addonStartup` cache drop + controlled Firefox restart |
| Firefox UI/content stylesheets synced from Linux | `<profile>/chrome/userChrome.css` and `userContent.css`; repaired for normal profiles |
| Santa package, extension, mode, profile, Safari identity/rule/process state | Audited when `SANTA_CHECKS=1`; Safari is denied only when `SANTA_ENFORCE_SAFARI=1` |
| Strict break schedule | Root-owned persisted scheduler plus a root-installed AppKit LaunchAgent covering every display |

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
active toggles would currently allow access. As in the Vivaldi sync, all six
sets have their schedule and limit fields overwritten, empty sets remain
inactive, and `sync`/`autoExportSync` are forced off so Firefox Sync cannot
restore the Linux-timed values on the Mac.

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
if a profile's `extensions.json` shows LeechBlock or PKF disabled or missing,
Firefox is quit, the entry is repaired in place, the startup cache is dropped,
and Firefox is relaunched — but only if it was already running, and at most
once per `EXT_RESTART_MIN_INTERVAL` (300 s) so a failing install cannot loop.
Private-window access is enforced by the Firefox policy profile. Although the
grant appears in `extension-preferences.json`, live Firefox testing showed that
external file repair plus startup-cache invalidation does not invoke Firefox's
internal permission API and can leave `about:addons` on Don't Allow. The
verifier therefore does not claim or attempt that unsupported repair. It does
fingerprint materialized managed preferences and performs one controlled
Firefox restart when an inactive profile becomes active or its payload changes.

Firefox is policy-gated: in daemon or repair mode, a missing profile, missing
managed-preferences file, or failed policy sentinel causes the verifier to quit
Firefox and suppress relaunch. A user can try to reopen it, but the 15-second
verification loop closes it again. Firefox becomes usable after the current
profile is installed and its managed preferences materialize; if it was closed
while unhealthy, launch it normally after activation.

## Layout

```text
ChickenBlocker-OSX/
  config/firefox-policies.json        canonical macOS Firefox policies
  config/breaks.json                  canonical strict break schedule
  config/santa-release.json           pinned Santa package provenance
  config/santa-rules.json             reviewed staged browser static rules
  agent/cb-break-overlay.swift        native multi-display break renderer
  agent/cb-break-overlay-Info.plist   background-app identity for notifications
  agent/com.chickenblocker.breaks.plist
  daemon/cb-verifier.sh               check & repair service (bash)
  daemon/com.chickenblocker.verifier.plist
  daemon/cb-release-client.py         signed appliance-release pull client
  daemon/com.chickenblocker.release.plist
  tools/gen-firefox-profile.py        generates the .mobileconfig (and plist)
  tools/break-scheduler.py             root-owned persisted schedule state machine
  tools/test-break-overlay.sh          unprivileged 30-second renderer test
  tools/publish-release.py             deterministic signed release publisher
  tools/build-release-bundle.py        fixed repository/rules bundle builder
  tools/stage-repository-release.sh    unprivileged appliance staging workflow
  tools/setup-release-appliance.sh     Debian static release service setup
  tools/install-release-client.sh      protected-Mac pull client bootstrap
  tools/gen-santa-profile.py          deterministic production/probe/rollback profiles
  tools/fetch-santa.sh                downloads and verifies the pinned official PKG
  tools/santa-probe.c                 no-side-effect disposable execution probe
  sync/extract_rules.py               Linux side: snapshot rules to staged/
  sync/sync-to-mac.sh                 build/stage a signed rules release
  install.sh / uninstall.sh           explicit local admin operations
  install-santa.sh                    explicit Phase 2 staging commands
```

## Signed appliance releases

The optional offline admin appliance provides a narrow signed pull channel.
Its signing private key never leaves the appliance. The Mac stores only the
public key and polls a read-only HTTP service over ZeroTier; every canonical
manifest is signature-checked, every payload is hash-checked, and lower release
sequences are rejected. Existing policy remains active while the appliance is
off.

On the Debian appliance, with this repository staged at
`/tmp/ChickenBlocker-OSX`:

```sh
su -c 'bash /tmp/ChickenBlocker-OSX/tools/setup-release-appliance.sh'
```

Copy `/etc/chickenblocker-release/signing-public.pem` to removable media or an
administrator-only temporary location on the Mac. Verify the SHA-256 public-key
fingerprint shown by the setup script at both ends. Then, from `svc-admin`:

```sh
sudo ./tools/install-release-client.sh /path/to/signing-public.pem
```

Publish the harmless create/remove smoke releases from the appliance console:

```sh
cb-publish-release --bundle /path/to/ChickenBlocker-OSX/release/smoke-add --sequence 1
cb-publish-release --bundle /path/to/ChickenBlocker-OSX/release/smoke-remove --sequence 2
```

Routine repository deployment never opens an SSH session to the protected Mac
and never asks the daily account for generic sudo. Build and upload an
unprivileged staging bundle, review it on the appliance, then publish it with an
explicit next sequence from the appliance console:

```sh
./tools/stage-repository-release.sh appliance-admin@10.11.133.222

# On the appliance console as root, after reviewing the staged files:
cb-publish-release \
  --bundle /home/appliance-admin/chickenblocker-release-staging/repository \
  --sequence N
```

The protected Mac verifies the manifest signature and payload before invoking
the fixed bundle installer. The release client runs the independent verifier
audit before recording the sequence as accepted.

## Install (fresh Mac)

```sh
# 1. From an administrator session on the Mac, bootstrap daemon + files.
sudo ./install.sh

# 2. on the Mac: grant Full Disk Access to the verifier's private interpreter
#    (NOT /bin/bash):
#    System Settings -> Privacy & Security -> Full Disk Access -> +
#    Cmd+Shift+G -> /Library/Application Support/ChickenBlocker/bin/cb-bash
sudo launchctl kickstart -k system/com.chickenblocker.verifier

# 3. one-time Firefox profile install on the Mac (macOS 27 has no CLI for it):
#    Finder -> Cmd+Shift+G -> /Library/Application Support/ChickenBlocker/expected
#    double-click org.mozilla.firefox.mobileconfig, then
#    System Settings -> General -> Device Management -> double-click the
#    downloaded profile -> Install -> Install (admin password)

# 4. Build and stage a signed rules release from the rule-source machine.
sync/sync-to-mac.sh appliance-admin@10.11.133.222
# Review and publish it at the appliance console as described above.
```

Step 2 is required because macOS TCC blocks even root LaunchDaemons from
reading browser profile data (`extensions.json`); the grant is scoped to the
ad-hoc-signed `cb-bash` copy so no other shell gains anything. Step 3 is
required because macOS 27 removed `profiles install`; the profile survives
Firefox updates and only changes when `config/firefox-policies.json` does.

### svc-admin is temporary

`svc-admin` exists only to bootstrap and approve the pieces above. Once setup
settles it is disabled, not deleted, and the signed pull channel becomes the
only routine privileged change path. Keep its account record, password,
`admin` membership, and Secure Token intact for recovery. Before disabling it,
every manual grant that needs administrator approval must be provisioned,
because a lost grant cannot be repaired locally once no enabled administrator
exists.

Run the pre-lock gates in this order while the daily standard user remains the
GUI console user:

1. From `svc-admin`, run `sudo ./install.sh` and install the signed release
   client if it is not already present.
2. In System Settings -> Privacy & Security -> Full Disk Access, add the exact
   private interpreter below and enable its switch with administrator
   authentication. macOS may automatically recreate its row after a protected
   access attempt, but the row is not a grant until its switch is enabled.

   ```text
   /Library/Application Support/ChickenBlocker/bin/cb-bash
   ```

3. Restart the verifier, wait for at least one cycle, and inspect the log:

   ```sh
   sudo launchctl kickstart -k system/com.chickenblocker.verifier
   sleep 20
   sudo tail -n 30 \
     "/Library/Application Support/ChickenBlocker/verifier.log"
   ```

   The new `verifier started` entry must not be followed by
   `EXTENSION-CHECK-ERROR`. A verifier audit launched through Terminal and
   `sudo` can still show `extension-state` and `profile-stylesheets` as skipped
   because macOS attributes that access to Terminal's responsible-process
   chain. The LaunchDaemon log, not those two manual skips, is the authoritative
   FDA check.
4. Gate the Accessibility grant and install the production root-owned helper
   while administrator approval remains available:

   ```sh
   ./tools/test-accessibility-grant.sh
   ./tools/test-accessibility-grant.sh --install-root
   ```

5. Reboot the Mac. As the daily user, verify the protected helper and all
   persistent jobs:

   ```sh
   ./tools/test-accessibility-grant.sh --verify-root
   launchctl print system/com.chickenblocker.verifier
   launchctl print system/com.chickenblocker.release
   launchctl print "gui/$(id -u)/com.chickenblocker.breaks"
   ```

   The verifier and break agent must be running. The release client normally
   exits after each poll, so `last exit code = 0` with its 60-second interval is
   healthy.
6. Bring the appliance online, verify that `current.json` is reachable, and
   confirm the release log reports `up-to-date` or a successfully applied
   increasing sequence:

   ```sh
   curl --fail http://10.11.133.222:8443/current.json
   sudo tail -n 30 \
     "/Library/Application Support/ChickenBlocker/release/release.log"
   ```

7. From `svc-admin`, run the final audit and require zero failures:

   ```sh
   sudo "/Library/Application Support/ChickenBlocker/bin/cb-bash" \
     "/Library/Application Support/ChickenBlocker/verifier.sh" check
   ```

   The two Terminal-attributed Firefox skips described in step 3 are acceptable
   only when the restarted LaunchDaemon log proves effective FDA.
8. Disable the account from its authenticated shell, then end that shell:

   ```sh
   sudo pwpolicy -u svc-admin disableuser
   exit
   ```

Do not delete `svc-admin`. Disabling it does not terminate an existing login
session, so `exit` is part of the procedure. Re-enable it only through an
authenticated recovery path or a reviewed signed appliance release running as
root. After disabling it, repeat one reboot and signed-release cycle before
considering the rollout settled.

The gate installs a probe app in `~/Applications` and proves that the
Accessibility grant works from the console user's session and survives a
rebuild signed with the same identity. macOS 27 also retained the grant across
an observed ad-hoc rebuild, but that may be TCC caching or looser matching and
is not a durable identity guarantee. Create a stable self-signed identity once
(Keychain Access → Certificate Assistant → Create Certificate → Identity
Type: Self Signed Root, Certificate Type: Code Signing), keep its private key,
and verify again after reboot. Only after that gate passes should `svc-admin`
be disabled.

The production helper is deployed root-owned under
`BASE/agent/ChickenBlocker AX Probe.app` (`--install-root`), so a standard
user cannot delete or replace it. Verified on macOS 27: disabling its
Device Control and Data Access grant in System Settings requires
administrator authentication, so a standard user cannot revoke it either;
`tccutil reset com.chickenblocker.ax-probe` also fails without privileges
and leaves the grant intact.
`tools/test-accessibility-grant.sh --verify-root` re-checks protection and
grant without any administrator.

### Accessibility profile transaction prototype (macOS 27)

The experimental helper in `agent/cb-ax-probe.swift` proves that a stably
signed user-session app can supervise the local configuration-profile UI. On
macOS 27 the TCC grant formerly named Accessibility appears under Privacy &
Security as **Device Control and Data Access**. Configuration profiles remain
under General → Device Management.

The observed removal flow is Device Management `-` → a confirmation sheet →
one combined `SecurityAgent` window containing administrator name, password,
Allow Access, and Don't Allow. The helper can identify profile detail sheets
by payload identifier, identify removal confirmations structurally by their
destructive button, cancel non-allowlisted operations, and terminate any
unarmed SecurityAgent window. Restarting System Settings with a verified new
PID clears the authorization state retained by that Settings process.

During the guarded `--install-profile` transaction the helper subscribes to
AX window/sheet-created notifications (plus System Settings and SecurityAgent
launch notifications) so each step runs the moment its window appears instead
of on a poll cadence, and it raises translucent, click-swallowing shield
panels tracked over the System Settings and SecurityAgent windows so the
console user cannot press Cancel or Don't Allow mid-transaction. The helper's
own interactions are AX actions and PID-targeted mouse events, which pass
under the shield; keyboard sabotage of System Settings (Cmd-Q) is not blocked,
but that only fails the transaction into the normal retry path.

Synthetic authorization was proven with a user-supplied svc-admin credential:
the helper first observes the exact allowlisted removal confirmation, verifies
Apple's SecurityAgent and a settled on-screen window, types `svc-admin` into
the focused username field, tabs to the secure password field, emits the
password one character per global HID event, and presses Allow Access. Bulk
Unicode injection, PID-targeted events, and injection before the window had
settled did not work. The successful test verified that the disposable profile
was removed and then restarted Settings.

The test credential is accepted through a clearly labelled hidden dialog and
transferred through a mode-0600 FIFO. It is not placed in command arguments,
environment variables, the clipboard, a regular file, or logs. Production
must replace svc-admin with a random one-time administrator created and
revoked by the root service; this prototype is not permission to retain a
standing administrator password in the user-session helper.

Repeat the mechanism tests with:

```sh
./tools/test-accessibility-grant.sh
./tools/test-pane-guard.sh
CB_TEST_BLOCKED_REMOVAL=1 ./tools/test-allowed-profile-removal.sh
./tools/test-allowed-profile-removal.sh
./tools/test-accessibility-auth-input.sh
./tools/test-accessibility-profile-install.sh
./tools/test-accessibility-profile-install.sh --cleanup-only
./tools/test-temp-admin-policy-update.sh
# Optional, persistent third-party installation:
./tools/test-temp-admin-policy-update.sh --virtualbox
```

The profile install test defaults to the two disposable `.mobileconfig`
fixtures under `tests/fixtures/`, or accepts initial and updated file paths as
its two arguments. Both files must have the same identifier, name, and stable
UUIDs; the update must increment `PayloadVersion`.
The helper opens the exact initial fixture, finds its Downloaded row by the
profile name plus `Profile not installed`, double-clicks it, and verifies its
display name and identifier before pressing Install. It repeats that flow with
the second fixture and drives Update/Replace. Before each transaction it uses
the Device Management minus button to remove a stale downloaded copy; macOS
does not expose a CLI for deleting a merely downloaded, not-installed profile.
The test verifies each UUID with
`system_profiler SPConfigurationProfileDataType -json`. A password prompt is
optional: System Settings remembers a successful authorization for a period,
so a missing SecurityAgent window is reported as cached authorization, not a
test failure. If the window appears, the helper uses the same FIFO and
per-character credential injection path proven by the removal test. It first
dismisses any separate `Profile Downloaded` or `Profile Installed` dialog with
an `OK` button discovered through Accessibility, so the global HID events
cannot be intercepted above SecurityAgent.

The temporary-admin policy test currently authenticates through `svc-admin` to
start its root phase and delete the temporary directory record afterward. Root
creates a random short-lived administrator without a secure token; macOS 27
still requires authenticated Open Directory authority to delete that record,
so the signed updater will need an equivalent root-held escrow credential. The
generated password crosses into the console-user helper through a mode-0600
FIFO, authorizes both profile installation and update, and is then discarded.
During those transactions a second helper disables the Device
Management minus/remove controls, cancels any removal confirmation that races
through, and rejects authorization windows not armed by the expected profile.
The account is deleted on success or failure.

With `--virtualbox`, the test also mounts the Arm64 DMG in the console user's
Downloads folder after staging a temporary root-readable copy in
`/Users/Shared`, requires the notarized Oracle installer identity `VB5E2TV963`,
and runs the package installer through authenticated `sudo` as the temporary
administrator. The staged image is removed afterward, but VirtualBox remains
installed. Any later macOS request to approve Oracle system software is a
separate manual approval, not the ChickenBlocker configuration-profile
transaction.

## Strict break overlay

The macOS port follows the Linux Safe Eyes split without running a GUI as
root. The verifier owns the schedule, state, and command file as root. A
root-installed Swift/AppKit binary runs in the console user's Aqua session and
only renders that command. Its borderless `screenSaver`-level windows cover all
displays and Spaces, with local time and battery/charging status in the
top-right corner. The system LaunchAgent uses `KeepAlive`; the root verifier
restores a booted-out or disabled agent and repairs changes to its binary,
plist, scheduler, and configuration.

The canonical schedule in `config/breaks.json` is:

- 30 minutes of awake work followed by a strict 5-minute break,
- a strict 30-minute break every fourth cycle,
- one continuous night overlay from midnight until 08:00,
- after 3 minutes without keyboard, mouse, or trackpad input, a Start-work gate
  pauses the timer until explicitly resumed,
- suspend time does not count as work; a sufficiently long sleep satisfies
  the pending break,
- no skip or postpone controls.

The menu-bar eye icon shows the current interval in the four-break cycle (for
example, `Interval: 1/4`), the next break time, and **Take a break now**. That
action can only move the next scheduled short or long break earlier; it cannot
postpone, shorten, or dismiss a break. The user agent writes a mode-`0600`
request, and the root scheduler validates its type, owner, age, and contents
before consuming it. The renderer is installed as the background application
`ChickenBlocker Breaks.app` so macOS can grant notification permission to its
stable `com.chickenblocker.breaks` identity. A one-shot notification announces
the upcoming short or long break `warning_seconds` before its root-owned
deadline (10 seconds in the canonical configuration). Accept macOS's
notification authorization prompt after the first bundled-agent launch; the
app then appears as **ChickenBlocker Breaks** in Notification settings.

As in the Linux Safe Eyes integration, a fullscreen **Start work** button is
shown after every completed daytime break and after the idle-away threshold.
A short away period preserves the work time that remained; a gate held for 30
minutes starts a fresh work interval. Strict breaks still expose no Skip or
Postpone controls.

The deployed configuration has `allow_escape: false`; Escape cannot dismiss an
active overlay. Killing the user renderer is transient because launchd restarts
it. The command file doubles as a verifier heartbeat: the verifier rewrites it
every check cycle, and when it has not been refreshed for 90 seconds — or the
verifier stays silent for 90 seconds after a wake — the renderer removes every
overlay, shows **Verifier inactive** in the menu, and keeps the screens
unlocked. A dead, hung, or uninstalled verifier therefore never leaves the
screen covered; the threshold can be tuned for tests with
`CB_BREAK_MAX_COMMAND_AGE` seconds. Before changing renderer behavior, use
`./tools/test-break-overlay.sh` for an unprivileged 30-second multi-display
test; it writes only to a temporary directory. Validate physical multi-display,
sleep/wake, login, and night-boundary behavior before publishing renderer or
schedule changes.

Calendar/camera-aware meeting pauses and the Linux post-break Start-work gate
are not part of this first port. They require separate macOS privacy and idle
state design rather than silently inheriting Linux assumptions.

## Sync rules from the Linux machine

Run on the Linux machine that has this repo checked out next to the
`ChickenBlocker` repo (or set `CB_LINUX_REPO`):

```sh
sync/sync-to-mac.sh                  # extract and build locally
sync/sync-to-mac.sh appliance-admin@10.11.133.222  # also upload to appliance staging
```

Extraction snapshots: LeechBlock settings (from Firefox's
`storage-sync-v2.sqlite`), the live PKF keyword manifest, the signed `.xpi`,
and the Linux repository's `userChrome.css`/`userContent.css`. Keyword words
are printed as counts only and are never committed. The LeechBlock snapshot
normalizes every populated set to always-blocked before it is staged. The
script never connects to the protected Mac: appliance-root review/signing and
the Mac's signature-verifying pull client are mandatory deployment boundaries.

## Verifier

```sh
sudo "$BASE/bin/cb-bash" "$BASE/verifier.sh" check    # one-shot audit (exit 1 on FAIL)
sudo "$BASE/bin/cb-bash" "$BASE/verifier.sh" repair   # one repair pass
sudo "$BASE/bin/cb-bash" "$BASE/verifier.sh" daemon   # loop (what the LaunchDaemon runs)
```

Checks run every `CHECK_INTERVAL` seconds (default 15). Missing, drifting,
or mis-permissioned files are reinstalled from the canonical copies and
logged to `BASE/verifier.log`. With `FIREFOX_PROFILE_REINSTALL=1`, a missing
or inactive Firefox configuration profile is reinstalled through the
root-owned, Accessibility-approved console helper. Config:
`BASE/verifier.conf` (`CHECK_INTERVAL`, `RESTART_FIREFOX_ON_REPAIR`,
`EXT_RESTART_MIN_INTERVAL`, `FIREFOX_PROFILE_REINSTALL`,
`FIREFOX_PROFILE_REPAIR_MIN_INTERVAL`, `SANTA_CHECKS`, `SANTA_ENFORCE_SAFARI`,
`SANTA_LOCAL_RULE_FALLBACK`, `SANTA_REINSTALL`; `FIREFOX_PROFILE_REPAIR_MIN_INTERVAL`
defaults to 60). Ordinary Phase 1 reinstalls preserve existing values and only
append missing safe defaults, except the `FIREFOX_PROFILE_REPAIR_MIN_INTERVAL`
300-to-60 default migration.

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
There is no Santa sync server, centralized enrollment, network extension,
Lockdown mode, path rule, file-access rule, or WebKit helper rule in this phase.

The source catalog also contains reviewed SigningID rules for nine alternative
browsers inspected from current notarized vendor artifacts. Those expanded
rules are staged but are not active on the target until a newly generated
production profile passes rollback and launch testing and is installed
manually. The currently installed profile still contains only the Safari rule.
Use `tools/inspect-browser-artifact.sh ARTIFACT APP_NAME.app` on the Mac to
repeat identity, signature, Gatekeeper, and artifact-digest inspection without
installing or launching the browser.

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

`PayloadRemovalDisallowed=true` adds local friction; it does not make the
profile non-removable.

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
7. Run `./install-santa.sh verify` and then the complete Safari acceptance matrix.

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
  under root by design.
- Santa blocks new Safari executions before useful browser code runs and is a
  stronger boundary than process killing, but Phase 2 remains friction-grade.
  The profile is locally installed, not centrally managed. An unrestricted local
  administrator can remove it, stop the verifier, use vendor uninstall paths,
  or modify local rules when no non-empty `StaticRules` profile is active.
- Safari Web Apps have a distinct identity, and embedded WebViews use shared
  WebKit components. Phase 2 blocks neither automatically.
- Root-resistant application restrictions and Recovery protections remain
  later work. Do not describe this implementation as root-resistant.
- The FDA grant covers only `BASE/bin/cb-bash` (deterministic ad-hoc
  signature; re-grant only if Apple updates `/bin/bash`).
