#!/usr/bin/env bash
# Deploy website HTML/CSS/JS/images to Tencent EdgeOne Makers (China).
# Does not upload the 50MB APK; the live page loads the APK from JSDMirror.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d)"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

mkdir -p "$STAGE"/{css,js,img,downloads}
cp "$ROOT/index.html" "$STAGE/"
cp "$ROOT/css/site.css" "$STAGE/css/"
cp "$ROOT/js/site.js" "$STAGE/js/"
cp "$ROOT/img/"* "$STAGE/img/"
cp "$ROOT/downloads/MANIFEST.json" "$STAGE/downloads/"

npx --yes edgeone makers deploy "$STAGE" --anonymous --site china -n yinwei --json
