#!/usr/bin/env bash
# Packaging inspection only; audible playback and HRTF need Mac hardware QA.
set -euo pipefail
APP="${1:?Usage: verify_macos_bundle.sh /path/to/Yinwei.app}"
[[ "$(uname -s)" == Darwin ]] || { echo "macOS is required" >&2; exit 1; }
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
BIN="$APP/Contents/MacOS/$EXECUTABLE"
LIB="$APP/Contents/Frameworks/libspatial_core.dylib"
test -f "$BIN"
test -f "$LIB"
ARCH_LIST="$(xcrun lipo -archs "$BIN")"
for arch in $ARCH_LIST; do
  xcrun lipo "$LIB" -verify_arch "$arch"
done
xcrun otool -L "$LIB"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
echo "Bundle/signature inspection passed. Native playback/HRTF acceptance is still required."
