#!/usr/bin/env python3
"""Stop file_picker SPM from compiling DKCamera / DKImagePickerController.

Yinwei iOS only opens audio/video through FileType.custom (UIDocumentPicker).
file_picker 8.3.7's Package.swift still links DKImagePickerController → DKCamera,
and DKCamera's -Owholemodule flag fails on Xcode 16 ("Owholemodule, expected -Onone").

Does not change Dart, DSP, HRTF, or Windows.
"""
from __future__ import annotations

import os
import pathlib
import re
import sys

DK_PACKAGE = re.compile(
    r"\.package\(\s*url:\s*\"[^\"]*DKImagePickerController[^\"]*\"[^)]*\),?\s*",
    re.MULTILINE,
)
DK_PRODUCT = re.compile(
    r"\.product\(\s*name:\s*\"DKImagePickerController\"[^)]*\),?\s*",
    re.MULTILINE,
)
PICKER_MEDIA = re.compile(r'\.define\(\s*"PICKER_MEDIA"\s*\),?\s*')
OWHOLE = re.compile(r"-Owholemodule")


def iter_roots() -> list[pathlib.Path]:
    roots: list[pathlib.Path] = []
    pub = os.environ.get("PUB_CACHE")
    if pub:
        roots.append(pathlib.Path(pub))
    home = pathlib.Path.home() / ".pub-cache"
    if home.exists():
        roots.append(home)
    if len(sys.argv) > 1:
        roots.extend(pathlib.Path(p) for p in sys.argv[1:])
    # Unique while preserving order.
    seen: set[str] = set()
    out: list[pathlib.Path] = []
    for root in roots:
        key = str(root.resolve()) if root.exists() else str(root)
        if key in seen:
            continue
        seen.add(key)
        out.append(root)
    return out


def patch_package_swift(path: pathlib.Path) -> bool:
    text = path.read_text(encoding="utf-8")
    if "DKImagePickerController" not in text and "PICKER_MEDIA" not in text:
        return False
    new = DK_PACKAGE.sub("", text)
    new = DK_PRODUCT.sub("", new)
    new = PICKER_MEDIA.sub("", new)
    if new == text:
        return False
    path.write_text(new, encoding="utf-8")
    print(f"patched Package.swift {path}")
    return True


def patch_owholemodule(path: pathlib.Path) -> bool:
    data = path.read_bytes()
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return False
    if "-Owholemodule" not in text:
        return False
    path.write_text(OWHOLE.sub("-Onone", text), encoding="utf-8")
    print(f"rewrote -Owholemodule {path}")
    return True


def main() -> int:
    changed = 0
    for root in iter_roots():
        if not root.exists():
            continue
        for path in root.rglob("Package.swift"):
            # Limit to file_picker / Flutter ephemeral plugin packages.
            lowered = str(path).replace("\\", "/").lower()
            if "file_picker" not in lowered and "fluttergeneratedplugin" not in lowered:
                continue
            if patch_package_swift(path):
                changed += 1
        for path in root.rglob("*"):
            if not path.is_file():
                continue
            if path.suffix.lower() not in {".pbxproj", ".xcconfig", ".swift"}:
                continue
            lowered = str(path).replace("\\", "/").lower()
            if not any(
                token in lowered
                for token in (
                    "dkcamera",
                    "dkimagepicker",
                    "dkphotogallery",
                    "file_picker",
                    "sourcepackages",
                )
            ):
                continue
            if path.stat().st_size > 4_000_000:
                continue
            try:
                sample = path.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            if "-Owholemodule" in sample and patch_owholemodule(path):
                changed += 1
    print(f"file_picker DKCamera patch files changed: {changed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
