#!/usr/bin/env python3
"""Verify the packaged device IPA itself, on CI or after artifact download."""
import argparse
import hashlib
import json
import plistlib
import struct
from pathlib import Path
from zipfile import ZipFile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def device_binary(data, label):
    require(len(data) >= 32, f"{label}: missing Mach-O header")
    magic, cpu, _, _, commands, command_size = struct.unpack_from("<6I", data)
    require(magic == 0xFEEDFACF and cpu == 0x0100000C,
            f"{label}: expected thin arm64 device executable")
    end = 32 + command_size
    require(end <= len(data), f"{label}: truncated load commands")
    cursor = 32
    device = False
    for _ in range(commands):
        require(cursor + 8 <= end, f"{label}: truncated command")
        command, size = struct.unpack_from("<2I", data, cursor)
        require(size >= 8 and cursor + size <= end, f"{label}: invalid command size")
        if command == 0x32:  # LC_BUILD_VERSION
            require(size >= 24, f"{label}: invalid build version")
            platform = struct.unpack_from("<I", data, cursor + 8)[0]
            require(platform == 2, f"{label}: platform {platform} is not iOS device")
            device = True
        elif command == 0x25:  # LC_VERSION_MIN_IPHONEOS, older toolchain
            device = True
        cursor += size
    require(device, f"{label}: iOS device platform is not declared")
    return "arm64 / iOS device"


def verify(path):
    app = "Payload/Runner.app/"
    extension = app + "PlugIns/YinweiBroadcastUpload.appex/"
    with ZipFile(path) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "Duplicate ZIP entries")
        require(not any(n.endswith("embedded.mobileprovision") for n in names),
                "Unsigned artifact unexpectedly includes a provisioning profile")
        app_info = plistlib.loads(archive.read(app + "Info.plist"))
        extension_info = plistlib.loads(archive.read(extension + "Info.plist"))
        modes = app_info.get("UIBackgroundModes", [])
        config = extension_info.get("NSExtension", {})
        process_mode = config.get("NSExtensionAttributes", {}).get("RPBroadcastProcessMode")
        require("audio" in modes, "Runner Info.plist is missing UIBackgroundModes audio")
        require(config.get("NSExtensionPointIdentifier") == "com.apple.broadcast-services-upload",
                "Wrong extension point")
        require(process_mode == "RPBroadcastProcessModeSampleBuffer",
                "Extension Info.plist has no sample-buffer broadcast process mode")
        binaries = {}
        for prefix, info in [(app, app_info), (extension, extension_info)]:
            executable = info["CFBundleExecutable"]
            require("/" not in executable and "\\" not in executable,
                    "Invalid executable name")
            label = prefix + executable
            binaries[label] = device_binary(archive.read(label), label)
    return {
        "ipa": path.name,
        "bytes": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "extension": extension.rstrip("/"),
        "RPBroadcastProcessMode": process_mode,
        "UIBackgroundModes": modes,
        "device_binaries": binaries,
        "provisioning_profiles": 0,
        "installation": "Unsigned; signing required before installation",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    result = json.dumps(verify(args.ipa), indent=2) + "\n"
    if args.report:
        args.report.write_text(result, encoding="utf-8")
    print(result, end="")
