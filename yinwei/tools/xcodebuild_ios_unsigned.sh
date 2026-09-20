#!/usr/bin/env bash
# Unsigned iphoneos xcodebuild for CI. Does not modify DSP/HRTF/audio.
#
# Usage:
#   ./yinwei/tools/xcodebuild_ios_unsigned.sh <ios_dir> <derived_data_dir>
set -euo pipefail

IOS_DIR="${1:?ios directory}"
DERIVED="${2:?derived data directory}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${XCODEBUILD_LOG_DIR:-/tmp/xcodebuild_logs}"
mkdir -p "$LOG_DIR" "$DERIVED"
LOG="$LOG_DIR/xcodebuild-unsigned.log"

cd "$IOS_DIR"

python3 "$SCRIPT_DIR/patch_ios_file_picker_no_dkcamera.py" \
  "$IOS_DIR" \
  "$IOS_DIR/Flutter/ephemeral" \
  "$DERIVED" \
  || true

run_unsigned_xcodebuild() {
  xcodebuild \
    -workspace Runner.xcworkspace \
    -scheme Runner \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY=- \
    EXPANDED_CODE_SIGN_IDENTITY=- \
    SWIFT_OPTIMIZATION_LEVEL=-Onone \
    SWIFT_COMPILATION_MODE=incremental \
    SWIFT_ENABLE_EXPLICIT_MODULES=NO \
    _EXPERIMENTAL_SWIFT_EXPLICIT_MODULES=NO \
    SWIFT_EMIT_MODULE_INTERFACE=NO \
    COMPILER_INDEX_STORE_ENABLE=NO \
    build
}

# Command-line settings override Runner xcconfig. file_picker/DKCamera is
# removed by the patcher; -Onone remains as a belt-and-suspenders override.
set +e +o pipefail
run_unsigned_xcodebuild 2>&1 | tee "$LOG"
xc_ok=${PIPESTATUS[0]}
if [[ "$xc_ok" -ne 0 ]]; then
  echo "xcodebuild failed; patching derived data and retrying once"
  python3 "$SCRIPT_DIR/patch_ios_file_picker_no_dkcamera.py" "$DERIVED" "$IOS_DIR" || true
  run_unsigned_xcodebuild 2>&1 | tee -a "$LOG"
  xc_ok=${PIPESTATUS[0]}
fi
set -euo pipefail

echo "===== xcodebuild errors (status ${xc_ok}) ====="
if [[ -f "$LOG" ]]; then
  grep -E "error:|fatal error:|Owholemodule|BUILD FAILED" "$LOG" | tail -n 80 || true
fi
echo "===== end xcodebuild errors ====="

exit "$xc_ok"
