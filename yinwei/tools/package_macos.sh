#!/usr/bin/env bash
# Build a universal offline test app, or a Developer ID release when credentials
# are explicitly supplied by the release environment. No credentials in source.
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS with Xcode is required' >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLAYER="$ROOT/apps/yinwei_player"
OUT="${YINWEI_MACOS_OUTPUT:-$ROOT/target/macos/distribution}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
SHA="$(git -C "$ROOT" rev-parse --short=12 HEAD)"
BUILD_NUMBER="${YINWEI_BUILD_NUMBER:-1}"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FLUTTER_VERSION="$(flutter --version | awk 'NR==1 {line=$0} END {print line}')"
XCODE_VERSION="$(xcodebuild -version | tr '\n' ' ')"

cd "$PLAYER"
# Match the package URLs recorded in the checked-in lockfile.
export PUB_HOSTED_URL=https://pub.dev
flutter pub get --enforce-lockfile
flutter build macos --release --build-number="$BUILD_NUMBER" \
  --dart-define="YINWEI_GIT_SHA=$SHA" \
  --dart-define="YINWEI_BUILD_NUMBER=$BUILD_NUMBER" \
  --dart-define="YINWEI_BUILD_TIMESTAMP=$TIMESTAMP" \
  --dart-define="YINWEI_FLUTTER_VERSION=$FLUTTER_VERSION" \
  --dart-define="YINWEI_XCODE_VERSION=$XCODE_VERSION" \
  --dart-define="YINWEI_WORKFLOW=macos-test-build" \
  --dart-define="YINWEI_PHASE=M2-M3-test"
APP="$PLAYER/build/macos/Build/Products/Release/Yinwei.app"
test -d "$APP"
APP_BIN="$APP/Contents/MacOS/Yinwei"
xcrun lipo "$APP_BIN" -verify_arch arm64 x86_64
xcrun lipo "$APP/Contents/Frameworks/libspatial_core.dylib" -verify_arch arm64 x86_64

IDENTITY="${YINWEI_MACOS_SIGN_IDENTITY:-}"
NOTARY="${YINWEI_MACOS_NOTARY_PROFILE:-}"
if [[ -n "$NOTARY" && -z "$IDENTITY" ]]; then
  echo 'A Developer ID identity is required for notarization.' >&2; exit 1
fi
if [[ -n "$IDENTITY" ]]; then
  while IFS= read -r component; do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$component"
  done < <(find "$APP/Contents/Frameworks" -depth \
    \( -name '*.framework' -o -name '*.dylib' \) -print)
  codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    --entitlements "$PLAYER/macos/Runner/Release.entitlements" "$APP"
fi
bash "$ROOT/tools/verify_macos_bundle.sh" "$APP"

NAME="Yinwei-macos-universal-$SHA"
ZIP="$OUT/$NAME.zip"
DMG="$OUT/$NAME.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
if [[ -n "$NOTARY" ]]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY" --wait
  xcrun stapler staple "$APP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi
STAGING="$(mktemp -d "$OUT/.dmg-staging.XXXXXX")"
ditto "$APP" "$STAGING/Yinwei.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -ov -volname 'Yinwei' -srcfolder "$STAGING" -format UDZO "$DMG"
if [[ -n "$NOTARY" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY" --wait
  xcrun stapler staple "$DMG"
fi
cp "$ROOT/docs/MACOS_FRIEND_TEST.md" "$OUT/START-HERE.md"
{
  echo 'Yinwei macOS universal test build'
  echo "Commit: $SHA"
  echo "Build: $BUILD_NUMBER"
  echo "Timestamp: $TIMESTAMP"
  echo "Flutter: $FLUTTER_VERSION"
  echo "Rust: $(rustc --version)"
  echo "Xcode: $XCODE_VERSION"
  echo "macOS build host: $(sw_vers -productVersion) / $(uname -m)"
  echo 'Architectures: arm64 + x86_64'
  if [[ -n "$NOTARY" ]]; then
    echo 'Signing: Developer ID, notarized'
  elif [[ -n "$IDENTITY" ]]; then
    echo 'Signing: Developer ID; NOT notarized'
  else
    echo 'Signing: ad-hoc TEST BUILD; NOT notarized'
  fi
  echo 'Hardware audio/HRTF/UI acceptance: pending tester verification'
} > "$OUT/BUILD-INFO.txt"
(cd "$OUT" && shasum -a 256 "$NAME.zip" "$NAME.dmg" > SHA256SUMS)
echo "Test package prepared: $ZIP"
echo "Test disk image prepared: $DMG"
