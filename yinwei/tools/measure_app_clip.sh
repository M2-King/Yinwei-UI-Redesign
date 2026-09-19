#!/usr/bin/env bash
# Measure the uncompressed App Clip package. Do not report Flutter Runner size.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: measure_app_clip.sh must run on macOS after an Xcode build." >&2
  echo "This host is $(uname -s). App Clip size is therefore unmeasured." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/apps/yinwei_player/ios"
CONFIG="${1:-Debug}"
DERIVED="${2:-}"

if [[ -z "$DERIVED" ]]; then
  DERIVED="$IOS/build/Build/Products/$CONFIG-iphoneos"
fi

CLIP="$DERIVED/YinweiClip.app"
EXT="$CLIP/PlugIns/YinweiClipLiveActivity.appex"

if [[ ! -d "$CLIP" ]]; then
  echo "ERROR: App Clip product not found: $CLIP" >&2
  echo "Build the YinweiClip target for a physical iPhone, then rerun." >&2
  exit 1
fi

bytes() {
  du -sk "$1" | awk '{print $1 * 1024}'
}

clip_bytes="$(bytes "$CLIP")"
ext_bytes=0
if [[ -d "$EXT" ]]; then
  ext_bytes="$(bytes "$EXT")"
fi

rust="not linked"
if nm -gU "$CLIP/YinweiClip" 2>/dev/null | grep -q yinwei_set_params; then
  rust="spatial_core symbols present (unexpected for first-slice Clip)"
else
  rust="spatial_core not linked (first-slice Clip stays lightweight)"
fi

echo "deployment_target=16.2"
echo "invocation_model=Xcode direct App Clip launch (no NFC/App Clip code required for local proof)"
echo "app_clip_uncompressed_bytes=$clip_bytes"
echo "app_clip_uncompressed_mib=$(awk -v b="$clip_bytes" 'BEGIN { printf "%.2f", b/1024/1024 }')"
echo "live_activity_extension_uncompressed_bytes=$ext_bytes"
echo "rust_staticlib=$rust"
echo "apple_app_clip_limit_note=Compare uncompressed thinned size against current Apple App Clip limit before linking spatial_core."
