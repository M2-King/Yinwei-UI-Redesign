#!/usr/bin/env bash
# Fail-fast toolchain gate for ios-27-live-transfer.
# Requires Xcode major >= 27 and iphoneos SDK major >= 27.
# Never switches DEVELOPER_DIR to Xcode 16.4.
set -euo pipefail

OUT="${1:-}"
LOG_TMP="$(mktemp)"
cleanup() { rm -f "$LOG_TMP"; }
trap cleanup EXIT

print_section() {
  echo
  echo "===== $1 ====="
}

{
  echo "Yinwei / 音围 iOS 27 live-transfer environment"
  echo "workflow: ios-27-live-transfer"
  echo "phase: 7D1 capture-only"
  echo "git SHA: ${CM_COMMIT:-unknown}"
  echo "branch: ${CM_BRANCH:-unknown}"
  echo "DEVELOPER_DIR: ${DEVELOPER_DIR:-unset}"
  echo "xcode-select: $(xcode-select -p 2>/dev/null || echo unknown)"
  print_section "sw_vers"
  sw_vers
  print_section "uname"
  uname -a
  print_section "xcodebuild -version"
  xcodebuild -version
  print_section "xcodebuild -showsdks"
  xcodebuild -showsdks
  print_section "swift --version"
  swift --version
  print_section "flutter --version"
  if command -v flutter >/dev/null 2>&1; then
    flutter --version
  else
    echo "flutter: not on PATH"
  fi
  print_section "rustc --version"
  if command -v rustc >/dev/null 2>&1; then
    rustc --version
  else
    echo "rustc: not installed yet"
  fi
} | tee "$LOG_TMP"

XCODE_LINE="$(xcodebuild -version 2>/dev/null | awk 'NR==1 {print}')"
XCODE_MAJOR="$(printf '%s\n' "$XCODE_LINE" | grep -oE '[0-9]+' | head -1 || true)"
SDK_VER="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || true)"
SDK_MAJOR="$(printf '%s\n' "$SDK_VER" | grep -oE '[0-9]+' | head -1 || true)"
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"

echo
echo "===== parsed toolchain ====="
echo "xcode_line: ${XCODE_LINE:-unknown}"
echo "xcode_major: ${XCODE_MAJOR:-unknown}"
echo "iphoneos_sdk: ${SDK_VER:-unknown}"
echo "iphoneos_sdk_major: ${SDK_MAJOR:-unknown}"
echo "iphoneos_sdk_path: ${SDK_PATH:-unknown}"

fail() {
  echo "ERROR: $1" >&2
  echo "Refusing to fall back to Xcode 16.4 or an older iOS SDK." >&2
  if [[ -n "$OUT" ]]; then
    cat "$LOG_TMP" >"$OUT"
    {
      echo
      echo "FAIL: $1"
    } >>"$OUT"
  fi
  exit 1
}

if [[ -z "$XCODE_MAJOR" ]]; then
  fail "could not parse Xcode major version from: ${XCODE_LINE:-empty}"
fi
if [[ "$XCODE_MAJOR" -lt 27 ]]; then
  fail "Xcode major is $XCODE_MAJOR (${XCODE_LINE}); ios-27-live-transfer requires Xcode 27+"
fi
if [[ -z "$SDK_MAJOR" ]]; then
  fail "could not parse iphoneos SDK version from: ${SDK_VER:-empty}"
fi
if [[ "$SDK_MAJOR" -lt 27 ]]; then
  fail "iphoneos SDK major is $SDK_MAJOR (${SDK_VER}); ios-27-live-transfer requires iOS 27 SDK"
fi

echo
echo "===== ScreenCaptureKit SDK presence ====="
if [[ -n "$SDK_PATH" && -d "$SDK_PATH" ]]; then
  INTERFACE="$(find "$SDK_PATH" -name 'ScreenCaptureKit.swiftinterface' 2>/dev/null | head -n 1 || true)"
  if [[ -z "$INTERFACE" ]]; then
    fail "Xcode 27 is selected but ScreenCaptureKit.swiftinterface was not found in $SDK_PATH"
  fi
  echo "ScreenCaptureKit.swiftinterface: $INTERFACE"
  for name in SCContentSharingPicker SCStream SCStreamConfiguration capturesAudio excludesCurrentProcessAudio SCStreamOutputType; do
    if grep -q "$name" "$INTERFACE"; then
      echo "FOUND $name"
    else
      echo "MISSING $name"
    fi
  done
else
  fail "iphoneos SDK path is missing"
fi

echo
echo "TOOLCHAIN_OK xcode_major=$XCODE_MAJOR iphoneos_sdk=$SDK_VER"
if [[ -n "$OUT" ]]; then
  cat "$LOG_TMP" >"$OUT"
  {
    echo
    echo "===== parsed toolchain ====="
    echo "xcode_line: ${XCODE_LINE}"
    echo "xcode_major: ${XCODE_MAJOR}"
    echo "iphoneos_sdk: ${SDK_VER}"
    echo "iphoneos_sdk_major: ${SDK_MAJOR}"
    echo "iphoneos_sdk_path: ${SDK_PATH}"
    echo "TOOLCHAIN_OK xcode_major=$XCODE_MAJOR iphoneos_sdk=$SDK_VER"
  } >>"$OUT"
  echo "Wrote $OUT"
fi
