#!/usr/bin/env bash
# Fetch the successful Android A2 APK from GitHub Actions.
# Requires authenticated gh for private artifacts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/downloads/Yinwei-Android-A2-Preview.apk"
EXPECTED_SHA="aaad5aae826e2001e0c62292bbd0d1abe27fc77c5b9800d75a07a6d8a52ab465"
RUN_ID="${YINWEI_ANDROID_RUN_ID:-35612161963}"
ARTIFACT_NAME="${YINWEI_ANDROID_ARTIFACT:-yinwei-android-live-transfer-a2}"
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

if [[ -f /tmp/a2-apk/yinwei-android-live-transfer-a2-36c7f96.apk ]]; then
  cp /tmp/a2-apk/yinwei-android-live-transfer-a2-36c7f96.apk "$OUT"
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
