#!/usr/bin/env python3
"""Publish a CI-built iPad IPA to the Yinwei update channel (developer, ios-arm64).

The iPad app then offers it ("Yinwei build N is ready" -> Download), and the
owner signs it with their signing app. This tool:

1. checks the IPA with verify_unsigned_ipa.py (device binaries, extension,
   Listen Room files);
2. reads its version from the app: <CFBundleShortVersionString>-dev.<CFBundleVersion>,
   where CI sets CFBundleVersion to its run number (the same number the app
   compares against);
3. copies it to the update server over SSH and runs the channel's own
   `channel.py publish` there, then checks the public manifest.

  python yinwei/tools/publish_ios_update.py IPA [--notes TEXT] [--dry-run]

--dry-run checks the IPA and prints the server commands without running them.
"""
import argparse
import hashlib
import json
import plistlib
import shlex
import subprocess
import sys
import urllib.request
from pathlib import Path
from zipfile import ZipFile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_unsigned_ipa import verify  # noqa: E402

HOST = "root@49.235.107.48"
REMOTE_TMP = "/tmp/yinwei-update-install"
CHANNEL_PY = "/opt/yinwei-update-channel/channel.py"
CATALOG = "/var/lib/yinwei-updates/catalog.json"
PACKAGES = "/var/lib/yinwei-updates/packages"
PUBLIC = "https://49.235.107.48/yinwei/updates"
PLATFORM = "ios-arm64"
CHANNEL = "developer"


def ipa_version(ipa: Path) -> str:
    with ZipFile(ipa) as archive:
        info = plistlib.loads(archive.read("Payload/Runner.app/Info.plist"))
    short = str(info.get("CFBundleShortVersionString", ""))
    build = str(info.get("CFBundleVersion", ""))
    if not build.isdigit() or int(build) <= 0:
        raise SystemExit(
            f"CFBundleVersion is {build!r}: not a CI run number. Only IPAs built by "
            "ios-unsigned-ipa.yml with --build-number can be published.")
    return f"{short}-dev.{build}"


def run(cmd: list[str], dry: bool, cwd: Path | None = None) -> None:
    print("+ " + " ".join(shlex.quote(c) for c in cmd))
    if not dry:
        subprocess.run(cmd, check=True, cwd=cwd)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--notes", default="")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    report = verify(args.ipa)
    version = ipa_version(args.ipa)
    name = f"Yinwei-iOS-{version}.ipa"
    digest = hashlib.sha256(args.ipa.read_bytes()).hexdigest()
    print(f"IPA checked: {version}, {report['bytes']} bytes, sha256 {digest}")

    remote_file = f"{REMOTE_TMP}/{name}"
    publish = " ".join(shlex.quote(c) for c in [
        "python3", CHANNEL_PY, "publish", "--catalog", CATALOG, "--packages", PACKAGES,
        "--public-base", PUBLIC, "--platform", PLATFORM, "--channel", CHANNEL,
        "--version", version, "--file", remote_file, "--notes", args.notes,
    ])
    # The channel service runs as www-data: it must be able to read both.
    finish = (f"chown www-data:www-data {shlex.quote(PACKAGES + '/' + PLATFORM)} "
              f"{shlex.quote(PACKAGES + '/' + PLATFORM + '/' + name)} {shlex.quote(CATALOG)}"
              f" && rm -f {shlex.quote(remote_file)}")
    run(["ssh", HOST, f"mkdir -p {shlex.quote(REMOTE_TMP)}"], args.dry_run)
    # From the file's own folder: a Windows "C:\..." source could read as a host.
    ipa = args.ipa.resolve()
    run(["scp", "-q", ipa.name, f"{HOST}:{remote_file}"], args.dry_run, cwd=ipa.parent)
    run(["ssh", HOST, f"{publish} && {finish}"], args.dry_run)
    if args.dry_run:
        print("Dry run: nothing was copied or published.")
        return

    with urllib.request.urlopen(f"{PUBLIC}/v1/{PLATFORM}/manifest.json", timeout=15) as r:
        manifest = json.load(r)
    mine = [x for x in manifest.get("releases", []) if x.get("version") == version]
    if not mine or mine[0].get("sha256") != digest:
        raise SystemExit(f"published manifest does not list {version} with this sha256")
    print(f"Published: {mine[0].get('uri')}")


if __name__ == "__main__":
    main()
