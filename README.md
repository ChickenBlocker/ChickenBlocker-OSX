# ChickenBlocker-OSX

macOS counterpart of [ChickenBlocker](../ChickenBlocker) (Linux), phase 1:
a root **LaunchDaemon that checks and re-asserts the Firefox policy files and
the LeechBlock / Page Keyword Filter blocking rules**, plus tooling that
syncs those rules from the Linux ChickenBlocker machine. It corresponds to
the verifier/policy layers of the macOS plan (`../ChickenBlocker/.kilo/plans/osx_version.md`,
sections 5, 7 and the local track in section 8); see
`../ChickenBlocker/.kilo/plans/osx_phase1.md` for the implemented/remaining
breakdown.

## What it enforces

| Expected (canonical) file                                    | Live target on the Mac |
| ------------------------------------------------------------ | ---------------------- |
| `config/firefox-policies.json` (installed to `BASE/expected/firefox-policies.json`) | `<Firefox.app>/Contents/Resources/distribution/policies.json` |
| pushed `leechblockng-managed-storage.json`                   | `/Library/Application Support/Mozilla/ManagedStorage/leechblockng@proginosko.com.json` |
| pushed `pkf-managed-storage.json`                            | `/Library/Application Support/Mozilla/ManagedStorage/page-keyword-filter-7f3a@local.addons.json` |
| pushed `extensions/page_keyword_filter.xpi`                  | `BASE/extensions/page_keyword_filter.xpi` |

`BASE` is `/Library/Application Support/ChickenBlocker`.

The Firefox policies block `about:addons`/`about:profiles`, private browsing
and developer tools, force-install **LeechBlock NG** (from the anonymous AMO
direct-download link — no account needed) and the **Page Keyword Filter**
extension (from the local `file://` copy of the signed `.xpi` pushed from
Linux — nothing is downloaded from AMO), and lock them against
removal/disabling. The LeechBlock settings themselves arrive as a Firefox
managed-storage manifest, snapshotted from the Linux machine's Firefox.

## Layout

```text
ChickenBlocker-OSX/
  config/firefox-policies.json        canonical macOS Firefox policies
  daemon/cb-verifier.sh               check & repair service (bash)
  daemon/com.chickenblocker.verifier.plist
  sync/extract_rules.py               Linux side: snapshot rules to staged/
  sync/sync-to-mac.sh                 Linux side: push staged/ to the Mac
  install.sh / uninstall.sh           local or over-SSH install (see below)
```

## Install

```sh
# on the Mac:
sudo ./install.sh

# from the Linux machine, over SSH (SSH is used ONLY when a target is given):
./install.sh user@mac-host
```

Then push the actual rules from the Linux machine (see below). The install
step alone already enforces the Firefox policies.

## Sync rules from the Linux machine

Run on the Linux machine that has this repo checked out next to the
`ChickenBlocker` repo:

```sh
sync/sync-to-mac.sh user@mac-host    # extract + push + repair + audit
sync/sync-to-mac.sh                  # extract only, into ./staged (gitignored)
```

Extraction snapshots: LeechBlock settings (from Firefox's
`storage-sync-v2.sqlite`), the live Page Keyword Filter keyword manifest, and
the signed `.xpi`. Keyword words are printed as counts only and are never
committed. After the push the verifier repairs the live files immediately and
prints an audit. Re-run whenever rules change on Linux.

## Verifier

```sh
sudo bash "$BASE/verifier.sh" check    # one-shot audit (exit 1 on FAIL)
sudo bash "$BASE/verifier.sh" repair   # one repair pass
sudo bash "$BASE/verifier.sh" daemon   # loop (what the LaunchDaemon runs)
```

Checks run every `CHECK_INTERVAL` seconds (default 15). Any missing,
drifting, or mis-permissioned live file is reinstalled from the canonical
copy and logged to `BASE/verifier.log`. When a managed-storage file had to be
repaired while Firefox is running, Firefox is quit and relaunched so
LeechBlock re-copies the managed configuration (disable via
`RESTART_FIREFOX_ON_REPAIR=0` in `BASE/verifier.conf`).

## Uninstall

```sh
sudo ./uninstall.sh          # on the Mac
./uninstall.sh user@mac-host # from Linux over SSH
```

Removes the daemon, all deployed files, and the Firefox `distribution`
policies; restart Firefox afterwards.

## Security posture (phase 1, honest limits)

- This is the **friction layer** of the local track: an unrestricted local
  root session can `launchctl bootout` the daemon and edit ordinary files.
  Drift is closed within seconds, but a minutes-long bypass window exists
  under root — exactly as documented in the plan's section 8.
- It is **not** the root-resistant execution boundary; native binary denial
  (MDM declarations or Santa) is a later phase and will make stopping this
  daemon irrelevant to browser enforcement.
- Firefox re-reads `policies.json` at startup; the verifier repairs files
  immediately, but an already-running Firefox picks changes up on next start
  (or on the controlled restart above).
