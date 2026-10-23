#!/bin/bash
set -euo pipefail
BARPILOT_TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BARPILOT_APP="${1:?Pass the BarPilot.app output directory}"
BARPILOT_MEDIA_SOURCE="$BARPILOT_TASK_ROOT/Vendor/mediaremote-adapter"
BARPILOT_MEDIA_BUILD="$BARPILOT_TASK_ROOT/.build/pro-media"
if [ ! -f "$BARPILOT_MEDIA_SOURCE/LICENSE" ]; then
  echo 'Missing BSD media helper sources. See Vendor/mediaremote-adapter.lock.json.' >&2
  exit 1
fi
cmake -S "$BARPILOT_MEDIA_SOURCE" -B "$BARPILOT_MEDIA_BUILD" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
cmake --build "$BARPILOT_MEDIA_BUILD" --target MediaRemoteAdapter -j 2
mkdir -p "$BARPILOT_APP/Contents/Frameworks" "$BARPILOT_APP/Contents/Resources/ProMedia" "$BARPILOT_APP/Contents/Resources/Licenses"
ditto "$BARPILOT_MEDIA_BUILD/MediaRemoteAdapter.framework" "$BARPILOT_APP/Contents/Frameworks/MediaRemoteAdapter.framework"
cp "$BARPILOT_MEDIA_SOURCE/bin/mediaremote-adapter.pl" "$BARPILOT_APP/Contents/Resources/ProMedia/mediaremote-adapter.pl"
cp "$BARPILOT_MEDIA_SOURCE/LICENSE" "$BARPILOT_APP/Contents/Resources/Licenses/MediaRemoteAdapter-BSD-3-Clause.txt"
cp "$BARPILOT_TASK_ROOT/Vendor/mediaremote-adapter.lock.json" "$BARPILOT_APP/Contents/Resources/Licenses/MediaRemoteAdapter-version.json"
codesign --force --sign - "$BARPILOT_APP/Contents/Frameworks/MediaRemoteAdapter.framework"
codesign --verify --deep --strict "$BARPILOT_APP/Contents/Frameworks/MediaRemoteAdapter.framework"
