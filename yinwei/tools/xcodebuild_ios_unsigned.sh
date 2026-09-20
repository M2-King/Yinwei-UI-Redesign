#!/usr/bin/env bash
# Unsigned iphoneos xcodebuild for CI. Does not modify DSP/HRTF/audio.
#
# Usage:
#   ./yinwei/tools/xcodebuild_ios_unsigned.sh <ios_dir> <derived_data_dir>
set -euo pipefail

IOS_DIR="${1:?ios directory}"
DERIVED="${2:?derived data directory}"

cd "$IOS_DIR"

# DKCamera (file_picker) still uses the removed -Owholemodule flag.
# Command-line settings override pod/SPM defaults. Unsigned CI only.
xcodebuild \
  -workspace Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  SWIFT_OPTIMIZATION_LEVEL=-Onone \
  SWIFT_COMPILATION_MODE=incremental \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build
