#!/usr/bin/env bash
# Build libspatial_core.so for Android A2 (arm64-v8a) and stage it into jniLibs.
#
# Does not commit the binary. CI copies this into the APK.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JNI_LIBS="${JNI_LIBS:-$ROOT/apps/yinwei_player/android/app/src/main/jniLibs}"
API="${ANDROID_API_LEVEL:-24}"
TARGET_TRIPLE="aarch64-linux-android"
ABI="arm64-v8a"

if [[ -z "${ANDROID_NDK_HOME:-}" && -n "${ANDROID_NDK_ROOT:-}" ]]; then
  export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
fi
if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
  echo "ANDROID_NDK_HOME is required" >&2
  exit 1
fi

HOST_TAG="${ANDROID_NDK_HOST_TAG:-}"
if [[ -z "$HOST_TAG" ]]; then
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) HOST_TAG=linux-x86_64 ;;
    Darwin-arm64) HOST_TAG=darwin-arm64 ;;
    Darwin-x86_64) HOST_TAG=darwin-x86_64 ;;
    *)
      echo "unknown host $(uname -s)-$(uname -m); set ANDROID_NDK_HOST_TAG" >&2
      exit 1
      ;;
  esac
fi

PREBUILT="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$HOST_TAG/bin"
CLANG="$PREBUILT/${TARGET_TRIPLE}${API}-clang"
AR="$PREBUILT/llvm-ar"
if [[ ! -x "$CLANG" ]]; then
  echo "missing NDK clang: $CLANG" >&2
  exit 1
fi

rustup target add "$TARGET_TRIPLE"

export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CLANG"
export CC_aarch64_linux_android="$CLANG"
export AR_aarch64_linux_android="$AR"
export CARGO_TERM_COLOR=always

# A2 JNI ingress does not need cpal/file-engine FFI.
(
  cd "$ROOT"
  cargo build -p spatial_core --release --target "$TARGET_TRIPLE" --no-default-features
)

SO_SRC="$ROOT/target/$TARGET_TRIPLE/release/libspatial_core.so"
if [[ ! -s "$SO_SRC" ]]; then
  echo "build produced empty or missing $SO_SRC" >&2
  exit 1
fi

DEST_DIR="$JNI_LIBS/$ABI"
mkdir -p "$DEST_DIR"
cp "$SO_SRC" "$DEST_DIR/libspatial_core.so"
SO_DEST="$DEST_DIR/libspatial_core.so"
BYTES="$(wc -c < "$SO_DEST" | tr -d ' ')"
echo "staged $SO_DEST ($BYTES bytes)"
if [[ "$BYTES" -lt 1000 ]]; then
  echo "libspatial_core.so is implausibly small" >&2
  exit 1
fi
if command -v file >/dev/null 2>&1; then
  file "$SO_DEST"
fi
