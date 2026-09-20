#!/usr/bin/env python3
"""Write the 7D1 source diagnostics manifest. Never includes captured PCM."""
from __future__ import annotations

import hashlib
import os
import sys

FILES = [
    "codemagic.yaml",
    "yinwei/tools/write_ios27_source_manifest.py",
    "yinwei/apps/yinwei_player/ios/Runner/YinweiScreenAudioProbe.swift",
    "yinwei/apps/yinwei_player/ios/Runner/YinweiDeveloperDiagnostics.swift",
    "yinwei/apps/yinwei_player/ios/Runner/AppDelegate.swift",
    "yinwei/apps/yinwei_player/lib/platform/screen_audio_probe.dart",
    "yinwei/apps/yinwei_player/lib/platform/developer_diagnostics.dart",
    "yinwei/apps/yinwei_player/lib/platform/build_stamp.dart",
    "yinwei/apps/yinwei_player/lib/mobile/developer_diagnostics_page.dart",
    "yinwei/apps/yinwei_player/lib/mobile/ios_screen_audio_probe_panel.dart",
]


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: write_ios27_source_manifest.py <output> <repo-root>", file=sys.stderr)
        return 2
    out, root = sys.argv[1], sys.argv[2]
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    missing = 0
    with open(out, "w", encoding="utf-8") as fh:
        fh.write("Yinwei iOS 27 7D1 source diagnostics manifest\n")
        fh.write("Never includes captured PCM.\n\n")
        for rel in FILES:
            path = os.path.join(root, rel)
            if not os.path.isfile(path):
                fh.write(f"MISSING  {rel}\n")
                missing += 1
                continue
            digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
            fh.write(f"{digest}  {rel}\n")
    print(f"Wrote {out}")
    return 1 if missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
