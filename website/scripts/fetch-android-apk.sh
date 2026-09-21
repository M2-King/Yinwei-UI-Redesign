#!/usr/bin/env bash
# Fetch the successful Android A1 APK from GitHub Actions.
# Requires authenticated gh for private artifacts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/downloads/Yinwei-Android-A1-Preview.apk"
EXPECTED_SHA="697325d506a6f7d4dd7f8d0b5c9437d400204c4da02af80ad54d6fab2a4b18fb"
RUN_ID="${YINWEI_ANDROID_RUN_ID:-35569621376}"
ARTIFACT_NAME="${YINWEI_ANDROID_ARTIFACT:-yinwei-android-live-transfer-a1}"
REPO="${YINWEI_GITHUB_REPO:-M2-King/Yinwei-UI-Redesign}"

mkdir -p "$ROOT/downloads"
if [[ -f "$OUT" ]]; then
  actual="$(sha256sum "$OUT" | awk '{print $1}')"
  if [[ "$actual" == "$EXPECTED_SHA" ]]; then
    echo "APK already present and hash matches: $OUT"
    exit 0
  fi
  echo "Existing APK hash mismatch; re-downloading."
fi

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

if [[ -f /tmp/yinwei-a1-apk/yinwei-android-live-transfer-a1-17bdc6b.apk ]]; then
  cp /tmp/yinwei-a1-apk/yinwei-android-live-transfer-a1-17bdc6b.apk "$OUT"
else
  gh run download "$RUN_ID" --repo "$REPO" -n "$ARTIFACT_NAME" -D "$tmp"
  found="$(find "$tmp" -name '*.apk' | head -n 1)"
  if [[ -z "$found" ]]; then
    echo "No APK found in artifact $ARTIFACT_NAME from run $RUN_ID" >&2
    exit 1
  fi
  cp "$found" "$OUT"
fi

actual="$(sha256sum "$OUT" | awk '{print $1}')"
if [[ "$actual" != "$EXPECTED_SHA" ]]; then
  echo "SHA-256 mismatch." >&2
  echo "expected $EXPECTED_SHA" >&2
  echo "actual   $actual" >&2
  exit 1
fi

echo "Wrote $OUT"
echo "SHA-256 $actual"
ls -l "$OUT"
