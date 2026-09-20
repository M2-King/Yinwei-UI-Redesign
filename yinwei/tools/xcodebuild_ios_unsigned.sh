#!/usr/bin/env bash
# Unsigned iphoneos xcodebuild for CI. Does not modify DSP/HRTF/audio.
#
# Usage:
#   ./yinwei/tools/xcodebuild_ios_unsigned.sh <ios_dir> <derived_data_dir>
set -euo pipefail

IOS_DIR="${1:?ios directory}"
DERIVED="${2:?derived data directory}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YINWEI_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEVICE_A="$YINWEI_ROOT/target/aarch64-apple-ios/release/libspatial_core.a"
FORCE_LOAD_XCCONFIG="$IOS_DIR/Flutter/spatial_core_force_load.xcconfig"
LOG_DIR="${XCODEBUILD_LOG_DIR:-/tmp/xcodebuild_logs}"
mkdir -p "$LOG_DIR" "$DERIVED"
LOG="$LOG_DIR/xcodebuild-unsigned.log"

if [[ ! -f "$DEVICE_A" ]]; then
  echo "ERROR: missing $DEVICE_A" >&2
  echo "Run tools/build_native_ios.sh so libspatial_core.a exists, then rebuild." >&2
  exit 1
fi
if [[ ! -f "$FORCE_LOAD_XCCONFIG" ]]; then
  echo "ERROR: missing $FORCE_LOAD_XCCONFIG" >&2
  echo "Run tools/build_native_ios.sh so -force_load is generated, then rebuild." >&2
  exit 1
fi

echo "===== spatial_core_force_load.xcconfig ====="
cat "$FORCE_LOAD_XCCONFIG"
echo "===== end spatial_core_force_load.xcconfig ====="
echo "DEVICE_A=$DEVICE_A"

# Nested OTHER_LDFLAGS[sdk=iphoneos*] in included xcconfigs is dropped by
# this xcodebuild destination. Pass -force_load on the command line so the
# static archive is actually linked. -u keeps Dart FFI dlsym roots alive
# through Release dead-strip. Do not use -exported_symbols_list (exclusive).
KEEP_SYMS="-u _yinwei_last_error -u _yinwei_open -u _yinwei_set_params -u _yinwei_play -u _yinwei_current_azimuth_deg -u _yinwei_dispose"
COREAUDIO_LIBS="-framework AVFoundation -framework AudioToolbox -framework CoreAudio -framework Accelerate -lc++"
# Appended by Runner OTHER_LDFLAGS = $(inherited) $(SPATIAL_CORE_FORCE_LDFLAGS).
# Do not assign OTHER_LDFLAGS here — that replaces Flutter's linker flags.
FORCE_LDFLAGS="-force_load ${DEVICE_A} ${KEEP_SYMS} ${COREAUDIO_LIBS}"
echo "SPATIAL_CORE_FORCE_LDFLAGS=$FORCE_LDFLAGS"

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
    STRIP_INSTALLED_PRODUCT=NO \
    STRIP_STYLE=non-global \
    SPATIAL_CORE_FORCE_LDFLAGS="$FORCE_LDFLAGS" \
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
  grep -E "error:|fatal error:|Owholemodule|BUILD FAILED|undefined symbol" "$LOG" | tail -n 80 || true
fi
echo "===== end xcodebuild errors ====="

exit "$xc_ok"
