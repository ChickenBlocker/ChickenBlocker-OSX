#!/bin/bash
# Copy Kilo access and the working repositories to svc-admin.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

MODE=full
case "$#" in
  0) ;;
  1) [ "$1" = --config-only ] || die "usage: $0 [--config-only]"
     MODE=config-only ;;
  *) die "usage: $0 [--config-only]" ;;
esac

TARGET_USER=svc-admin
SOURCE_AUTH="$HOME/.local/share/kilo/auth.json"
SOURCE_CONFIG="$HOME/.config/kilo/kilo.jsonc"
SOURCE_READLINE="$HOME/kilo-readline"
KILO=/opt/homebrew/bin/kilo
SCRIPT_DIR=$(/usr/bin/dirname "$0")
SOURCE_REPO=$(/usr/bin/git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel) \
  || die "could not locate this repository"
REPO_NAME=$(/usr/bin/basename "$SOURCE_REPO")

[ "$(uname -s)" = Darwin ] || die "this tool must run on macOS"
[ "$(id -u)" -ne 0 ] || die "run this as the source user, not with sudo"
[ -f "$SOURCE_CONFIG" ] || die "Kilo config not found: $SOURCE_CONFIG"
/usr/bin/id "$TARGET_USER" >/dev/null 2>&1 || die "user not found: $TARGET_USER"

if [ "$MODE" = full ]; then
  [ -f "$SOURCE_AUTH" ] || die "Kilo credentials not found: $SOURCE_AUTH"
  [ -d "$SOURCE_READLINE" ] || die "project not found: $SOURCE_READLINE"
  [ -x "$KILO" ] || die "shared Kilo installation not found: $KILO"
  JQ=$(command -v jq) || die "jq is required"
  "$JQ" -e 'has("openai") and (.openai != null)' "$SOURCE_AUTH" \
    >/dev/null || die "OpenAI credentials are missing from $SOURCE_AUTH"
fi

HOME_RECORD=$(/usr/bin/dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory) \
  || die "could not read the home directory for $TARGET_USER"
TARGET_HOME=${HOME_RECORD#NFSHomeDirectory: }
case "$TARGET_HOME" in
  /Users/*) ;;
  *) die "unexpected home directory for $TARGET_USER: $TARGET_HOME" ;;
esac
[ -d "$TARGET_HOME" ] || die "target home does not exist: $TARGET_HOME"

TARGET_GROUP=$(/usr/bin/id -gn "$TARGET_USER")
TARGET_KILO_DIR="$TARGET_HOME/.local/share/kilo"
TARGET_AUTH="$TARGET_KILO_DIR/auth.json"
TARGET_CONFIG_DIR="$TARGET_HOME/.config/kilo"
TARGET_CONFIG="$TARGET_CONFIG_DIR/kilo.jsonc"
TARGET_READLINE="$TARGET_HOME/kilo-readline"
TARGET_REPO="$TARGET_HOME/projects/$REPO_NAME"

echo "Administrator authentication is required to copy files to $TARGET_USER."
/usr/bin/sudo -v

if [ "$MODE" = full ]; then
  if /usr/bin/sudo /bin/test -e "$TARGET_AUTH"; then
    die "refusing to overwrite existing credentials: $TARGET_AUTH"
  fi
  if /usr/bin/sudo /bin/test -e "$TARGET_READLINE"; then
    die "refusing to overwrite existing project: $TARGET_READLINE"
  fi
  if /usr/bin/sudo /bin/test -e "$TARGET_REPO"; then
    die "refusing to overwrite existing repository: $TARGET_REPO"
  fi
fi

for directory in \
  "$TARGET_HOME/.config" \
  "$TARGET_CONFIG_DIR" \
  "$TARGET_HOME/.local" \
  "$TARGET_HOME/.local/share" \
  "$TARGET_KILO_DIR" \
  "$TARGET_HOME/projects"
do
  /usr/bin/sudo /usr/bin/install -d -m 0700 \
    -o "$TARGET_USER" -g "$TARGET_GROUP" "$directory"
done

/usr/bin/sudo /usr/bin/install -m 0600 \
  -o "$TARGET_USER" -g "$TARGET_GROUP" "$SOURCE_CONFIG" "$TARGET_CONFIG"

if [ "$MODE" = config-only ]; then
  /usr/bin/sudo -u "$TARGET_USER" /bin/test -r "$TARGET_CONFIG"
  /usr/bin/sudo -k
  echo "Copied the Kilo config to $TARGET_CONFIG."
  exit 0
fi

# Stream only the OpenAI entry; never create a plaintext staging file.
"$JQ" '{openai: .openai}' "$SOURCE_AUTH" \
  | /usr/bin/sudo -u "$TARGET_USER" /bin/sh -c \
      'umask 077; /usr/bin/tee "$1" >/dev/null' sh "$TARGET_AUTH"

/usr/bin/sudo /usr/bin/ditto --noqtn "$SOURCE_READLINE" "$TARGET_READLINE"
/usr/bin/sudo /usr/sbin/chown -R \
  "$TARGET_USER:$TARGET_GROUP" "$TARGET_READLINE"

# ditto includes hidden, ignored, and untracked content, including .git/.kilo.
/usr/bin/sudo /usr/bin/ditto --noqtn "$SOURCE_REPO" "$TARGET_REPO"
/usr/bin/sudo /usr/sbin/chown -R \
  "$TARGET_USER:$TARGET_GROUP" "$TARGET_REPO"

/usr/bin/sudo -u "$TARGET_USER" /bin/test -r "$TARGET_AUTH"
/usr/bin/sudo -u "$TARGET_USER" "$JQ" -e 'keys == ["openai"]' \
  "$TARGET_AUTH" >/dev/null
/usr/bin/sudo -u "$TARGET_USER" /bin/test -d "$TARGET_READLINE"
/usr/bin/sudo -u "$TARGET_USER" /bin/test -d "$TARGET_REPO/.git"
/usr/bin/sudo -u "$TARGET_USER" /bin/test -f \
  "$TARGET_REPO/.kilo/plans/manual-mdm-self-restriction.md"
/usr/bin/sudo -u "$TARGET_USER" /usr/bin/env HOME="$TARGET_HOME" \
  "$KILO" --version >/dev/null

/usr/bin/sudo -k
echo "Copied the Kilo config, OpenAI credential, and working repositories to $TARGET_HOME."
echo "Verified the shared Kilo installation for $TARGET_USER."
