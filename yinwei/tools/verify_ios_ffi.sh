#!/usr/bin/env bash
# Verify yinwei_* symbols in the linked iOS Runner after Xcode/Flutter build.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: verify_ios_ffi.sh must run on macOS." >&2
  exit 1
fi

BIN="${1:-}"
if [[ -z "$BIN" ]]; then
  echo "Usage: $0 /path/to/Runner.app/Runner" >&2
  exit 1
fi
if [[ ! -f "$BIN" ]]; then
  echo "ERROR: binary not found: $BIN" >&2
  exit 1
fi

REQUIRED=(
  yinwei_last_error
  yinwei_open
  yinwei_set_params
  yinwei_play
  yinwei_current_azimuth_deg
  yinwei_dispose
)

exports="$(nm -gU "$BIN" 2>/dev/null || nm -g "$BIN")"
missing=()
for sym in "${REQUIRED[@]}"; do
  if ! grep -q "$sym" <<<"$exports"; then
    missing+=("$sym")
  fi
done

if ((${#missing[@]} > 0)); then
  echo "ERROR: linked Runner is missing: ${missing[*]}" >&2
  echo "Runner must link Native/libspatial_core.xcframework and compile Runner/spatial_core_ffi_keep.c." >&2
  echo "Run tools/build_native_ios.sh, then rebuild the unsigned iphoneos Runner." >&2
  echo "===== nm globals (head) =====" >&2
  echo "$exports" | head -n 40 >&2 || true
  echo "===== nm yinwei =====" >&2
  nm "$BIN" 2>/dev/null | grep -i yinwei >&2 || true
  exit 1
fi

echo "FFI symbols reachable in $BIN"
if grep -qi 'spatial_core.dll' <<<"$exports"; then
  echo "ERROR: Windows DLL string present in iOS binary" >&2
  exit 1
fi
