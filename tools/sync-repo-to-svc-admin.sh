#!/bin/bash
# One-way mirror of this complete checkout, including ignored files, to svc-admin.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

TARGET_USER=svc-admin
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SOURCE_REPO=$(/usr/bin/git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel) \
  || die "could not locate this repository"
REPO_NAME=$(/usr/bin/basename "$SOURCE_REPO")

[ "$(uname -s)" = Darwin ] || die "this tool must run on macOS"
[ "$(id -u)" -ne 0 ] || die "run this as the source user, not with sudo"
/usr/bin/id "$TARGET_USER" >/dev/null 2>&1 || die "user not found: $TARGET_USER"

HOME_RECORD=$(/usr/bin/dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory) \
  || die "could not read the home directory for $TARGET_USER"
TARGET_HOME=${HOME_RECORD#NFSHomeDirectory: }
[ "$TARGET_HOME" = "/Users/$TARGET_USER" ] || \
  die "unexpected home directory for $TARGET_USER: $TARGET_HOME"

TARGET_GROUP=$(/usr/bin/id -gn "$TARGET_USER")
TARGET_PARENT="$TARGET_HOME/projects"
TARGET_REPO="$TARGET_PARENT/$REPO_NAME"

echo "Administrator authentication is required to sync to $TARGET_REPO."
/usr/bin/sudo -v

if /usr/bin/sudo /bin/test -L "$TARGET_REPO"; then
  die "refusing to replace a symlinked destination: $TARGET_REPO"
fi
if /usr/bin/sudo /bin/test -e "$TARGET_REPO" && \
   ! /usr/bin/sudo /bin/test -d "$TARGET_REPO"; then
  die "destination exists but is not a directory: $TARGET_REPO"
fi

/usr/bin/sudo /usr/bin/install -d -o "$TARGET_USER" -g "$TARGET_GROUP" \
  -m 0700 "$TARGET_PARENT" "$TARGET_REPO"

# This is an intentional one-way mirror. Dotfiles, .git, .kilo, ignored, and
# untracked files are included; target-only files are removed.
/usr/bin/sudo /usr/bin/rsync -a --delete "$SOURCE_REPO/" "$TARGET_REPO/"
/usr/bin/sudo /usr/sbin/chown -R "$TARGET_USER:$TARGET_GROUP" "$TARGET_REPO"

/usr/bin/sudo /usr/bin/cmp \
  "$SOURCE_REPO/.kilo/plans/manual-mdm-self-restriction.md" \
  "$TARGET_REPO/.kilo/plans/manual-mdm-self-restriction.md"
/usr/bin/sudo -u "$TARGET_USER" /usr/bin/git -C "$TARGET_REPO" status \
  --short >/dev/null

/usr/bin/sudo -k
echo "Mirrored $SOURCE_REPO to $TARGET_REPO, including ignored plan files."
