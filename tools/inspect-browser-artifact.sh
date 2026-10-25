#!/bin/bash
# Inspect a downloaded macOS browser without installing or launching it.
set -eu

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "this tool must run on macOS"
[ "$#" = 2 ] || die "usage: $0 ARTIFACT APP_NAME.app"

ARTIFACT=$1
APP_NAME=$2
[ -f "$ARTIFACT" ] || die "artifact not found: $ARTIFACT"
case "$APP_NAME" in
  */*|.|..) die "APP_NAME must be a top-level .app name" ;;
  *.app) ;;
  *) die "APP_NAME must end in .app" ;;
esac

WORK=$(mktemp -d /tmp/chickenblocker-browser-inspect.XXXXXX)
MOUNTED=0
cleanup() {
  if [ "$MOUNTED" = 1 ]; then
    hdiutil detach "$WORK/mount" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM

case "$ARTIFACT" in
  *.dmg)
    mkdir "$WORK/mount"
    hdiutil attach -readonly -nobrowse -mountpoint "$WORK/mount" "$ARTIFACT" \
      >/dev/null
    MOUNTED=1
    ROOT="$WORK/mount"
    ;;
  *.zip)
    mkdir "$WORK/extracted"
    ditto -x -k "$ARTIFACT" "$WORK/extracted"
    ROOT="$WORK/extracted"
    ;;
  *) die "unsupported artifact type (expected .dmg or .zip)" ;;
esac

SOURCE_APP="$ROOT/$APP_NAME"
[ -d "$SOURCE_APP" ] || die "application not found at artifact root: $APP_NAME"
# Model the installed bundle without installing it. Vendor disk images can
# carry Finder metadata that is not part of the code signature and causes
# strict verification directly on the read-only image to fail.
mkdir "$WORK/staged"
ditto --noextattr --noqtn "$SOURCE_APP" "$WORK/staged/$APP_NAME"
APP="$WORK/staged/$APP_NAME"
xattr -cr "$APP"
INFO="$APP/Contents/Info.plist"
[ -f "$INFO" ] || die "application has no Contents/Info.plist"
EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO")
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")
BINARY="$APP/Contents/MacOS/$EXECUTABLE"
[ -x "$BINARY" ] || die "main executable not found: $EXECUTABLE"

SANTACTL=/usr/local/bin/santactl
[ -x "$SANTACTL" ] || SANTACTL=/Applications/Santa.app/Contents/MacOS/santactl
[ -x "$SANTACTL" ] || die "santactl not found"

echo "artifact=$ARTIFACT"
echo "artifact_sha256=$(shasum -a 256 "$ARTIFACT" | cut -d ' ' -f 1)"
echo "app=$APP_NAME"
echo "version=$VERSION"
echo "bundle_id=$BUNDLE_ID"
echo "executable=$EXECUTABLE"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$BINARY" 2>&1
echo "santa_signing_id=$($SANTACTL fileinfo --key 'Signing ID' "$BINARY")"
echo "gatekeeper_assessment:"
spctl --assess --type execute --verbose=2 "$APP"
