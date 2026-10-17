#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAYER="$ROOT/apps/yinwei_player"
CAPTURE_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yinwei-capture-tests.XXXXXX")"
trap 'rm -rf "$CAPTURE_TEST_DIR"' EXIT
xcrun --sdk macosx swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  "$PLAYER/ios/Shared/YinweiCaptureSupport.swift" \
  "$PLAYER/test/native_capture/main.swift" -o "$CAPTURE_TEST_DIR/capture-tests"
"$CAPTURE_TEST_DIR/capture-tests" "$PLAYER/test/fixtures/ios_capture/five_groups_profile.plist"
