# ChickenBlocker-OSX

macOS counterpart of [ChickenBlocker](../ChickenBlocker) (Linux), phase 1:
a root **LaunchDaemon that checks and re-asserts the Firefox policy channel
and the LeechBlock / Page Keyword Filter blocking rules**, plus tooling that
syncs those rules from the Linux ChickenBlocker machine. It corresponds to
the verifier/policy layers of the macOS plan (`../ChickenBlocker/.kilo/plans/osx_version.md`,
sections 5, 7 and the local track in section 8); see
`../ChickenBlocker/.kilo/plans/osx_phase1.md` for the implemented/remaining
breakdown and the macOS 27 findings (TCC, profiles, channels).

## What it enforces

| Channel                                                       | Live target on the Mac |
| ------------------------------------------------------------- | ---------------------- |
| Firefox policies — user configuration profile `com.chickenblocker.firefox` (managed `org.mozilla.firefox` preferences) | User profile; verifier checks presence and materialized policy sentinels every cycle |
| LeechBlock settings — managed-storage manifest                | `/Library/Application Support/Mozilla/ManagedStorage/leechblockng@proginosko.com.json` |
| PKF keyword list — managed-storage manifest                   | `/Library/Application Support/Mozilla/ManagedStorage/page-keyword-filter-7f3a@local.addons.json` |
| PKF extension `.xpi` (signed copy pushed from Linux; space-free `file://` URL) | `/usr/local/lib/ChickenBlocker/page_keyword_filter.xpi` (+ legacy copy under `BASE/extensions/`) |
| Extension state — LeechBlock/PKF present and active in every Firefox profile | `<profile>/extensions.json`, repaired in place + `addonStartup` cache drop + controlled Firefox restart |
| Firefox UI/content stylesheets synced from Linux | `<profile>/chrome/userChrome.css` and `userContent.css`; repaired for normal profiles |

`BASE` is `/Library/Application Support/ChickenBlocker`.

The Firefox policies block `about:addons`/`about:profiles`, private browsing
and developer tools, force-install **LeechBlock NG** (anonymous AMO
direct-download link — no account) and the **Page Keyword Filter** extension
(local `file://` xpi — nothing is downloaded from AMO), and lock both against
removal/disabling. The LeechBlock settings arrive as a managed-storage
manifest, snapshotted from the Linux machine's Firefox.

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
  daemon/cb-verifier.sh               check & repair service (bash)
  daemon/com.chickenblocker.verifier.plist
  tools/gen-firefox-profile.py        generates the .mobileconfig (and plist)
  sync/extract_rules.py               Linux side: snapshot rules to staged/
  sync/sync-to-mac.sh                 Linux side: push staged/ to the Mac
  install.sh / uninstall.sh           local or over-SSH install (see below)
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
are printed as counts only and are never committed.

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
`EXT_RESTART_MIN_INTERVAL`).

## Uninstall

```sh
sudo ./uninstall.sh          # on the Mac (also removes the managed prefs file)
./uninstall.sh user@mac-host # from Linux over SSH
```

Also remove the profile manually (System Settings → General → Device
Management → −) and the FDA grant if desired; restart Firefox afterwards.

## Security posture (phase 1, honest limits)

- This is the **friction layer** of the local track: an unrestricted local
  root session can `launchctl bootout` the daemon, remove the profile via
  System Settings, and edit ordinary files. Drift is closed within seconds
  (profile loss: hourly warning), but a minutes-long bypass window exists
  under root — exactly as documented in the plan's section 8.
- It is **not** the root-resistant execution boundary; native binary denial
  (MDM declarations or Santa) is a later phase and will make stopping this
  daemon irrelevant to browser enforcement.
- The FDA grant covers only `BASE/bin/cb-bash` (deterministic ad-hoc
  signature; re-grant only if Apple updates `/bin/bash`).
