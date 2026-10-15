#!/usr/bin/env python3
"""Extract ChickenBlocker (Linux) blocking rules for macOS deployment.

Runs on the LINUX ChickenBlocker machine. Produces macOS-ready files:

  leechblockng-managed-storage.json
      Firefox managed-storage manifest for LeechBlock NG (>= 1.7.3): a
      snapshot of this machine's LeechBlock settings, read from Firefox's
      storage-sync-v2.sqlite (ext_id leechblockng@proginosko.com). Every
      populated set is forced active 24/7 with no time allowance, matching the
      Linux Firefox-to-Vivaldi synchronization semantics.
  pkf-managed-storage.json
      The live Page Keyword Filter managed-storage manifest (title/body
      keyword list), copied verbatim.
  extensions/page_keyword_filter.xpi
      The signed PKF extension (force-installed on the Mac via a file://
      install_url; nothing is downloaded from AMO).
  userChrome.css / userContent.css
      Firefox profile UI/content hardening copied from the Linux repository.

Keyword words are never printed (counts only) and never committed: the output
directory defaults to <repo>/staged, which is gitignored.

Usage:
  extract_rules.py [--out DIR] [--linux-repo DIR] [--sqlite PATH]
                   [--pkf-manifest PATH] [--xpi PATH]

Environment: CB_LINUX_REPO overrides the Linux ChickenBlocker repo location
(default: the ChickenBlocker directory next to this repository).
"""
import argparse
import glob
import json
import os
import shutil
import sqlite3
import subprocess
import sys

EXT = "leechblockng@proginosko.com"
PKF_EXT_ID = "page-keyword-filter-7f3a@local.addons"
NUM_SETS = 6
ALL_DAYS = [True] * 7


def die(msg):
    sys.exit("ERROR: %s" % msg)


def find_linux_repo(cli_value):
    candidates = []
    if cli_value:
        candidates.append(cli_value)
    if os.environ.get("CB_LINUX_REPO"):
        candidates.append(os.environ["CB_LINUX_REPO"])
    repo_parent = os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))
    candidates.append(os.path.join(repo_parent, "ChickenBlocker"))
    for c in candidates:
        if c and os.path.isfile(os.path.join(c, "policies.json")):
            return c
    die("cannot locate the Linux ChickenBlocker repo; pass --linux-repo DIR "
        "or set CB_LINUX_REPO (expected a sibling 'ChickenBlocker' directory)")


def parse_ini(ini_path):
    sections = []
    cur = None
    with open(ini_path, "r") as f:
        for line in f:
            line = line.strip()
            if line.startswith("[") and line.endswith("]"):
                if cur is not None:
                    sections.append(cur)
                cur = {"_kind": line[1:-1]}
            elif "=" in line and cur is not None:
                k, _, v = line.partition("=")
                cur[k.strip()] = v.strip()
    if cur is not None:
        sections.append(cur)
    return sections


def sqlite_candidates(home):
    bases = [
        os.path.join(home, "snap/firefox/common/.mozilla/firefox"),
        os.path.join(home, ".mozilla/firefox"),
    ]
    out = []
    for base in bases:
        ini = os.path.join(base, "profiles.ini")
        if not os.path.isfile(ini):
            continue
        sections = parse_ini(ini)
        profiles = [s for s in sections if s["_kind"].startswith("Profile")]
        installs = [s for s in sections if s["_kind"].startswith("Install")]
        rel = next((p["Path"] for p in profiles
                    if p.get("Default") == "1" and p.get("Path")), None)
        if rel is None:
            rel = next((p["Path"] for p in profiles if p.get("Path")), None)
        if rel:
            out.append(os.path.join(base, rel, "storage-sync-v2.sqlite"))
        for i in installs:
            if i.get("Default"):
                out.append(os.path.join(i["Default"], "storage-sync-v2.sqlite"))
    return out


def infer_sqlite_path(explicit):
    if explicit:
        return explicit
    for cand in sqlite_candidates(os.path.expanduser("~")):
        if os.path.isfile(cand):
            return cand
    die("could not infer Firefox storage-sync-v2.sqlite (no profiles.ini with "
        "a usable profile); pass --sqlite PATH")


def read_leechblock_settings(sqlite_path):
    try:
        con = sqlite3.connect("file:%s?mode=ro" % sqlite_path, uri=True, timeout=5)
    except sqlite3.Error as e:
        die("cannot open %s: %s" % (sqlite_path, e))
    try:
        row = con.execute(
            "SELECT data FROM storage_sync_data WHERE ext_id=?", (EXT,)).fetchone()
    except sqlite3.Error as e:
        die("cannot read LeechBlock row from %s: %s (Firefox running with a "
            "write lock? stop it and re-run)" % (sqlite_path, e))
    finally:
        con.close()
    if not row or not row[0]:
        die("no LeechBlock data in %s — is LeechBlock installed and configured "
            "on this machine?" % sqlite_path)
    try:
        return json.loads(row[0])
    except ValueError as e:
        die("LeechBlock settings are not valid JSON: %s" % e)


def set_is_populated(settings, n):
    sites = settings.get("sites%d" % n, "")
    if not isinstance(sites, str):
        sites = ""
    return (bool(sites.strip()) or
            bool(settings.get("keywordRE%d" % n)) or
            bool(settings.get("regexpBlock%d" % n)))


def force_populated_sets_always_blocked(settings):
    """Return a Firefox config with every populated set blocking 24/7."""
    out = dict(settings)
    # Match cb_vv_leechblock.py: keep this machine on local extension storage
    # so Firefox Sync cannot restore the Linux schedules after import.
    out["sync"] = False
    out["autoExportSync"] = False
    source_num_sets = settings.get("numSets", NUM_SETS)
    try:
        num_sets = int(source_num_sets)
    except (TypeError, ValueError):
        num_sets = NUM_SETS
    num_sets = max(1, min(NUM_SETS, num_sets))

    highest_populated = 0
    for n in range(1, NUM_SETS + 1):
        populated = set_is_populated(settings, n)
        if populated:
            highest_populated = n
        out["activeBlock%d" % n] = populated
        out["days%d" % n] = list(ALL_DAYS)
        out["times%d" % n] = "0000-2359"
        out["limitMins%d" % n] = ""
        out["limitPeriod%d" % n] = ""
        out["limitOffset%d" % n] = ""
        out["disable%d" % n] = False

    num_sets = max(num_sets, highest_populated)
    out["numSets"] = (str(num_sets)
                      if isinstance(source_num_sets, str) else num_sets)
    return out


def read_bytes(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except PermissionError:
        r = subprocess.run(["sudo", "-n", "cat", path], capture_output=True)
        if r.returncode == 0:
            return r.stdout
        die("%s is not readable and passwordless sudo failed (run with sudo "
            "or: sudo cat %s > somewhere-readable)" % (path, path))
    except OSError as e:
        die("cannot read %s: %s" % (path, e))


def find_pkf_manifest(explicit):
    if explicit:
        return explicit
    home = os.path.expanduser("~")
    for p in (
        os.path.join(home, "snap/firefox/common/.mozilla/managed-storage",
                     "%s.json" % PKF_EXT_ID),
        os.path.join(home, ".mozilla/managed-storage", "%s.json" % PKF_EXT_ID),
    ):
        if os.path.isfile(p):
            return p
    die("cannot find the Page Keyword Filter managed-storage manifest; "
        "pass --pkf-manifest PATH")


def find_xpi(explicit, linux_repo):
    if explicit:
        return explicit
    system = "/etc/firefox/cb-extensions/page_keyword_filter.xpi"
    if os.path.isfile(system):
        return system
    xpis = sorted(glob.glob(os.path.join(
        linux_repo, "cb_keyword_block/web-ext-artifacts/*.xpi")),
        key=os.path.getmtime, reverse=True)
    if xpis:
        return xpis[0]
    return None


def keyword_counts(lb):
    sites5 = lb.get("sites5") or ""
    kw5 = [t[1:] for t in sites5.split() if t.startswith("~") and len(t) > 1]
    rb6 = lb.get("regexpBlock6") or ""
    kw6 = [w for w in rb6.split("|") if w]
    return len(kw5), len(kw6)


def write_json(path, obj):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")


def main():
    ap = argparse.ArgumentParser(add_help=True, description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=None, help="output dir (default: <repo>/staged)")
    ap.add_argument("--linux-repo", default=None, help="Linux ChickenBlocker repo")
    ap.add_argument("--sqlite", default=None, help="storage-sync-v2.sqlite path")
    ap.add_argument("--pkf-manifest", default=None, help="PKF manifest path")
    ap.add_argument("--xpi", default=None, help="page_keyword_filter.xpi path")
    args = ap.parse_args()

    linux_repo = find_linux_repo(args.linux_repo)
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = args.out or os.path.join(repo_root, "staged")
    os.makedirs(os.path.join(out, "extensions"), exist_ok=True)

    sqlite_path = infer_sqlite_path(args.sqlite)
    lb = force_populated_sets_always_blocked(
        read_leechblock_settings(sqlite_path))
    write_json(os.path.join(out, "leechblockng-managed-storage.json"), {
        "name": EXT,
        "description": "LeechBlock NG settings synced from the Linux "
                       "ChickenBlocker machine (managed storage)",
        "type": "storage",
        "data": lb,
    })

    pkf_path = find_pkf_manifest(args.pkf_manifest)
    pkf_raw = read_bytes(pkf_path)
    try:
        pkf = json.loads(pkf_raw.decode("utf-8"))
        pkf_kw = len((pkf.get("data") or {}).get("keywords") or [])
    except ValueError:
        die("PKF manifest %s is not valid JSON" % pkf_path)
    with open(os.path.join(out, "pkf-managed-storage.json"), "wb") as f:
        f.write(pkf_raw)

    xpi_path = find_xpi(args.xpi, linux_repo)
    if xpi_path:
        data = read_bytes(xpi_path)
        with open(os.path.join(out, "extensions/page_keyword_filter.xpi"), "wb") as f:
            f.write(data)

    for name in ("userChrome.css", "userContent.css"):
        src = os.path.join(linux_repo, name)
        if not os.path.isfile(src):
            die("missing Firefox profile stylesheet: %s" % src)
        shutil.copyfile(src, os.path.join(out, name))

    kw5, kw6 = keyword_counts(lb)
    populated = sum(1 for n in range(1, NUM_SETS + 1)
                    if set_is_populated(lb, n))
    print("LeechBlock settings : %s" % sqlite_path)
    print("  numSets=%s populated/forced=%d  set5 keywords=%d  "
          "set6 url-words=%d" % (
        lb.get("numSets", "?"),
        populated,
        kw5, kw6))
    print("PKF manifest        : %s (keywords=%d)" % (pkf_path, pkf_kw))
    if xpi_path:
        print("PKF extension (.xpi): %s (%d bytes)" % (xpi_path, len(data)))
    else:
        print("PKF extension (.xpi): NOT FOUND — PKF cannot force-install on "
              "the Mac until an xpi is available", file=sys.stderr)
    print("Profile stylesheets   : userChrome.css, userContent.css")
    print("staged -> %s" % out)


if __name__ == "__main__":
    main()
