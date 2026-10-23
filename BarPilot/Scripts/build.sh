#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_MODE="${1:-release}"
BARPILOT_SIGN_IDENTITY="${BARPILOT_SIGN_IDENTITY:-}"
if [ -z "$BARPILOT_SIGN_IDENTITY" ] && [ -f "$TASK_ROOT/.local/barpilot-signing-identity" ]; then
    IFS= read -r BARPILOT_SIGN_IDENTITY < "$TASK_ROOT/.local/barpilot-signing-identity"
fi
BARPILOT_SIGN_IDENTITY="${BARPILOT_SIGN_IDENTITY:--}"
case "$BUILD_MODE" in release|debug) ;; *) echo 'Usage: bash Scripts/build.sh [release|debug]' >&2; exit 2 ;; esac
cd "$TASK_ROOT"
swift build -c "$BUILD_MODE" --product BarPilot
BARPILOT_BIN="$(swift build -c "$BUILD_MODE" --show-bin-path)/BarPilot"
APP_DIR="$TASK_ROOT/dist/BarPilot.app"
if [ -d "$APP_DIR" ]; then rm -rf "$APP_DIR"; fi
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BARPILOT_BIN" "$APP_DIR/Contents/MacOS/BarPilot"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.pakwingho.barpilot</string>
<key>CFBundleName</key><string>BarPilot</string>
<key>CFBundleDisplayName</key><string>BarPilot</string>
<key>CFBundleExecutable</key><string>BarPilot</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.5.1</string>
<key>CFBundleVersion</key><string>18</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>local.pakwingho.barpilot.menu-item</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
<key>UTTypeDescription</key><string>BarPilot menu item</string>
</dict></array>
<key>CFBundleIconFile</key><string>BarPilot.icns</string>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>local.pakwingho.barpilot</string>
<key>CFBundleURLSchemes</key><array><string>barpilot</string></array>
</dict></array>
</dict></plist>
PLIST
python3 "$TASK_ROOT/../scripts/localization/package-resources.py" "$(dirname "$BARPILOT_BIN")" "$APP_DIR" BarPilot_BarPilotCore
xcrun swift "$TASK_ROOT/Scripts/make-icon.swift" "$APP_DIR/Contents/Resources"
codesign --force --sign "$BARPILOT_SIGN_IDENTITY" --identifier local.pakwingho.barpilot "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
# A generated bundle must not become the allowlist's preferred application record.
REGISTER_TOOL='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
"$REGISTER_TOOL" -u "$APP_DIR" >/dev/null 2>&1 || true
if [ -d /Applications/BarPilot.app ] &&
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/BarPilot.app/Contents/Info.plist)" = 'local.pakwingho.barpilot' ]; then
    "$REGISTER_TOOL" -f /Applications/BarPilot.app
fi
echo "Built: $APP_DIR"
