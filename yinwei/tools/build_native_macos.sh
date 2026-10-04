#!/usr/bin/env bash
# Build the existing realtime engine; optionally embed it in an Xcode app.
# Usage: bash tools/build_native_macos.sh [arm64|x86_64|universal|xcode]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-arm64}"
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail "macOS with Xcode is required."
for tool in cargo rustup xcrun; do
  command -v "$tool" >/dev/null || fail "$tool is required."
done

# In Xcode, satisfy precisely the app architectures, including universal builds.
case "$MODE" in
  arm64) ARCH_LIST="arm64" ;;
  x86_64) ARCH_LIST="x86_64" ;;
  universal) ARCH_LIST="arm64 x86_64" ;;
  xcode) ARCH_LIST="${ARCHS:?Xcode ARCHS is required}" ;;
  *) fail "Unknown mode: $MODE" ;;
esac

if [[ -n "${MACOSX_DEPLOYMENT_TARGET:-}" ]]; then
  export MACOSX_DEPLOYMENT_TARGET
fi
LIBS=()
for arch in $ARCH_LIST; do
  case "$arch" in
    arm64) target=aarch64-apple-darwin ;;
    x86_64) target=x86_64-apple-darwin ;;
    *) fail "Unsupported macOS architecture: $arch" ;;
  esac
  rustup target add "$target"
  cargo build --manifest-path "$ROOT/Cargo.toml" --locked \
    --target-dir "$ROOT/target" -p spatial_core --release --target "$target"
  LIBS+=("$ROOT/target/$target/release/libspatial_core.dylib")
done

OUT_DIR="$ROOT/target/macos/$MODE"
mkdir -p "$OUT_DIR"
LIBRARY="$OUT_DIR/libspatial_core.dylib"
if [[ ${#LIBS[@]} -eq 1 ]]; then
  cp "${LIBS[0]}" "$LIBRARY"
else
  xcrun lipo -create "${LIBS[@]}" -output "$LIBRARY"
fi
xcrun install_name_tool -id '@rpath/libspatial_core.dylib' "$LIBRARY"
# install_name_tool changes signed Mach-O bytes. Sign this standalone output as
# well as the embedded copy so ARM64 native smoke tests can load it safely.
/usr/bin/codesign --force --sign - --timestamp=none "$LIBRARY"
for arch in $ARCH_LIST; do
  xcrun lipo "$LIBRARY" -verify_arch "$arch"
  # Inspect every slice, not just the host slice. No pipes with early exit.
  SYMBOLS="$(xcrun nm -arch "$arch" -gU "$LIBRARY")"
  for symbol in yinwei_last_error yinwei_open yinwei_set_params yinwei_get_params \
      yinwei_play yinwei_pause yinwei_seek_ms yinwei_export_wav \
      yinwei_current_azimuth_deg yinwei_current_elevation_deg yinwei_dispose; do
    [[ "$SYMBOLS" == *"_$symbol"* ]] || fail "Missing $arch export: $symbol"
  done
done
xcrun otool -L "$LIBRARY"

if [[ "$MODE" == xcode ]]; then
  FRAMEWORK_DIR="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}"
  mkdir -p "$FRAMEWORK_DIR"
  EMBEDDED="$FRAMEWORK_DIR/libspatial_core.dylib"
  cp "$LIBRARY" "$EMBEDDED"
  # The outer app is signed by Xcode after this build phase. Sign the nested
  # library with the same identity; use ad-hoc signing for local builds.
  if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
    IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
    [[ -n "$IDENTITY" ]] || IDENTITY=-
    if [[ "$IDENTITY" == - ]]; then
      /usr/bin/codesign --force --sign - --timestamp=none "$EMBEDDED"
    else
      /usr/bin/codesign --force --sign "$IDENTITY" --timestamp "$EMBEDDED"
    fi
  fi
  echo "Embedded spatial_core: $EMBEDDED"
else
  echo "Built spatial_core: $LIBRARY"
fi
