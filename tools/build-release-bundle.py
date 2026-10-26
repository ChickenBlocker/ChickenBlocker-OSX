#!/usr/bin/env python3
"""Build reviewed repository or rule-update release bundles."""

import argparse
import os
import shutil
import stat
import tempfile
from pathlib import Path


REPOSITORY_PATHS = ("agent", "config", "daemon", "tools", "install.sh")
RULE_FILES = (
    "leechblockng-managed-storage.json",
    "pkf-managed-storage.json",
    "userChrome.css",
    "userContent.css",
)

REPOSITORY_INSTALLER = """#!/bin/bash
# Apply a reviewed ChickenBlocker repository snapshot.
set -euo pipefail

[[ $(uname -s) == Darwin ]] || { echo "ERROR: repository release requires macOS" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "ERROR: repository release requires root" >&2; exit 1; }
[[ ${CB_RELEASE_SEQUENCE:-} =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: invalid release sequence" >&2; exit 1; }

REPOSITORY=$(cd "$(dirname "$0")/repository" && pwd)
exec /bin/bash "$REPOSITORY/install.sh" --local
"""

RULES_INSTALLER = """#!/bin/bash
# Apply reviewed browser-rule snapshots through the local verifier.
set -euo pipefail

[[ $(uname -s) == Darwin ]] || { echo "ERROR: rules release requires macOS" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "ERROR: rules release requires root" >&2; exit 1; }
[[ ${CB_RELEASE_SEQUENCE:-} =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: invalid release sequence" >&2; exit 1; }

SOURCE=$(cd "$(dirname "$0")/rules" && pwd)
BASE="/Library/Application Support/ChickenBlocker"
EXPECTED="$BASE/expected"
[[ -x "$BASE/bin/cb-bash" && -f "$BASE/verifier.sh" && -d "$EXPECTED" ]] || {
  echo "ERROR: ChickenBlocker verifier is not installed" >&2
  exit 1
}

install -d -o root -g wheel -m 0755 "$EXPECTED/extensions"
found=0
for name in leechblockng-managed-storage.json pkf-managed-storage.json userChrome.css userContent.css; do
  if [[ -f "$SOURCE/$name" ]]; then
    install -m 0644 -o root -g wheel "$SOURCE/$name" "$EXPECTED/$name"
    found=1
  fi
done
if [[ -f "$SOURCE/extensions/page_keyword_filter.xpi" ]]; then
  install -m 0644 -o root -g wheel "$SOURCE/extensions/page_keyword_filter.xpi" \
    "$EXPECTED/extensions/page_keyword_filter.xpi"
  found=1
fi
[[ $found -eq 1 ]] || { echo "ERROR: rules release contains no supported files" >&2; exit 1; }
"$BASE/bin/cb-bash" "$BASE/verifier.sh" repair
"""


class BundleError(Exception):
    pass


def copy_regular(source, destination):
    mode = source.lstat().st_mode
    if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
        raise BundleError(f"unsupported source entry: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    destination.chmod(stat.S_IMODE(mode))


def copy_tree(source, destination):
    if source.is_symlink() or not source.is_dir():
        raise BundleError(f"source directory is invalid: {source}")
    destination.mkdir(parents=True, exist_ok=True)
    for path in sorted(source.rglob("*"), key=lambda item: item.as_posix()):
        relative = path.relative_to(source)
        if "__pycache__" in relative.parts or path.name == ".DS_Store" or path.suffix == ".pyc":
            continue
        target = destination / relative
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            raise BundleError(f"source links are forbidden: {path}")
        if stat.S_ISDIR(mode):
            target.mkdir(parents=True, exist_ok=True)
        elif stat.S_ISREG(mode):
            copy_regular(path, target)
        else:
            raise BundleError(f"unsupported source entry: {path}")


def build_repository(source, output):
    repository = output / "repository"
    for relative in REPOSITORY_PATHS:
        path = source / relative
        target = repository / relative
        if path.is_dir():
            copy_tree(path, target)
        elif path.is_file():
            copy_regular(path, target)
        else:
            raise BundleError(f"required repository path is missing: {path}")
    (output / "install.sh").write_text(REPOSITORY_INSTALLER)
    (output / "install.sh").chmod(0o755)


def build_rules(source, output):
    rules = output / "rules"
    copied = 0
    for relative in RULE_FILES:
        path = source / relative
        if path.exists():
            copy_regular(path, rules / relative)
            copied += 1
    extension = source / "extensions" / "page_keyword_filter.xpi"
    if extension.exists():
        copy_regular(extension, rules / "extensions" / extension.name)
        copied += 1
    if copied == 0:
        raise BundleError(f"no supported staged rule files found in {source}")
    (output / "install.sh").write_text(RULES_INSTALLER)
    (output / "install.sh").chmod(0o755)


def build(kind, source, output):
    source = source.resolve()
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=output.name + ".new-", dir=output.parent))
    try:
        if kind == "repository":
            build_repository(source, temporary)
        elif kind == "rules":
            build_rules(source, temporary)
        else:
            raise BundleError(f"unsupported bundle kind: {kind}")
        if output.exists():
            if output.is_symlink() or not output.is_dir():
                raise BundleError(f"refusing to replace non-directory output: {output}")
            shutil.rmtree(output)
        os.replace(temporary, output)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("repository", "rules"))
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        build(args.kind, args.source, args.output)
    except BundleError as error:
        raise SystemExit(f"ERROR: {error}")
    print(args.output.resolve())


if __name__ == "__main__":
    main()
