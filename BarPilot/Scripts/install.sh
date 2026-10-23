#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="${1:-/Applications}"
case "$DEST_DIR" in /*) ;; *) echo 'Installation directory must be an absolute path.' >&2; exit 2 ;; esac
SOURCE_APP="$TASK_ROOT/dist/BarPilot.app"
ENTRY_APP="$DEST_DIR/BarPilot.app"
TARGET_APP="$ENTRY_APP"
# MenuBarAgent on macOS 27 fails to allowlist the controller on the Work volume.
# Keep a Work entry while running the actual, registered system Applications copy.
MACOS_MAJOR="$(/usr/bin/sw_vers -productVersion | cut -d . -f 1)"
if [ "$MACOS_MAJOR" -ge 27 ]; then TARGET_APP='/Applications/BarPilot.app'; fi
REGISTER_TOOL='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
test -d "$SOURCE_APP"
codesign --verify --deep --strict "$SOURCE_APP"
for CHECK_APP in "$TARGET_APP" "$ENTRY_APP"; do
    if [ -L "$CHECK_APP" ]; then
        test "$CHECK_APP" = "$ENTRY_APP"
        test "$(readlink "$CHECK_APP")" = "$TARGET_APP"
    elif [ -e "$CHECK_APP" ]; then
        BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CHECK_APP/Contents/Info.plist")"
        test "$BUNDLE_ID" = 'local.pakwingho.barpilot'
    fi
done
mkdir -p "$DEST_DIR" "$(dirname "$TARGET_APP")"
STAGING_DIR="$(mktemp -d "$(dirname "$TARGET_APP")/.barpilot-install.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$SOURCE_APP" "$STAGING_DIR/BarPilot.app"
codesign --verify --deep --strict "$STAGING_DIR/BarPilot.app"
if pgrep -f '/BarPilot.app/Contents/MacOS/BarPilot' >/dev/null; then
    osascript -e 'tell application id "local.pakwingho.barpilot" to quit'
    for ATTEMPT in {1..30}; do
        if ! pgrep -f '/BarPilot.app/Contents/MacOS/BarPilot' >/dev/null; then break; fi
        sleep 0.2
    done
    if pgrep -f '/BarPilot.app/Contents/MacOS/BarPilot' >/dev/null; then
        echo 'BarPilot is still running; installation stopped.' >&2; exit 1
    fi
fi
# Unregister only our replaced/generated copies, never other applications.
"$REGISTER_TOOL" -u "$SOURCE_APP" >/dev/null 2>&1 || true
"$REGISTER_TOOL" -u "$TARGET_APP" >/dev/null 2>&1 || true
if [ "$ENTRY_APP" != "$TARGET_APP" ]; then
    "$REGISTER_TOOL" -u "$ENTRY_APP" >/dev/null 2>&1 || true
fi
BACKUP_DIR="$(mktemp -d "$DEST_DIR/.BarPilot-backups.XXXXXX")"
if [ -d "$TARGET_APP" ]; then
    mv "$TARGET_APP" "$BACKUP_DIR/BarPilot.installed.app"
fi
if [ "$ENTRY_APP" != "$TARGET_APP" ]; then
    if [ -L "$ENTRY_APP" ]; then
        rm "$ENTRY_APP"
    elif [ -d "$ENTRY_APP" ]; then
        mv "$ENTRY_APP" "$BACKUP_DIR/BarPilot.work.app"
    fi
fi
mv "$STAGING_DIR/BarPilot.app" "$TARGET_APP"
if [ "$ENTRY_APP" != "$TARGET_APP" ]; then ln -s "$TARGET_APP" "$ENTRY_APP"; fi
"$REGISTER_TOOL" -f "$TARGET_APP"
echo "Installed: $TARGET_APP"
if [ "$ENTRY_APP" != "$TARGET_APP" ]; then echo "Work entry: $ENTRY_APP"; fi
