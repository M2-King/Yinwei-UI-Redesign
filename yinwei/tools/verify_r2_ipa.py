"""Inspect public R2 bundle/capability metadata without extracting profiles.

This is structural verification, not cryptographic code-signature validation.
No passwords, profile contents, certificates or account identifiers are printed.
"""
import argparse
import hashlib
import json
import plistlib
import struct
import zipfile

GROUP = "group.dev.yinwei.remote.capture"


def signature_groups(binary):
    if len(binary) < 32 or binary[:4] != b"\xcf\xfa\xed\xfe":
        return [], False
    offset = 32
    commands = struct.unpack_from("<I", binary, 16)[0]
    for _ in range(min(commands, 4096)):
        command, length = struct.unpack_from("<II", binary, offset)
        if length < 8 or offset + length > len(binary):
            raise ValueError("Invalid Mach-O command bounds")
        if command == 0x1D:
            start, size = struct.unpack_from("<II", binary, offset + 8)
            blob = binary[start:start + size]
            magic, total, count = struct.unpack_from(">III", blob)
            if magic != 0xFADE0CC0 or total > len(blob) or count > 4096:
                raise ValueError("Invalid signature container")
            for index in range(count):
                _, position = struct.unpack_from(">II", blob, 12 + index * 8)
                kind, extent = struct.unpack_from(">II", blob, position)
                if kind == 0xFADE7171:
                    entitlements = plistlib.loads(blob[position + 8:position + extent])
                    return entitlements.get("com.apple.security.application-groups", []), True
            return [], True
        offset += length
    return [], False


def inspect(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError("IPA ZIP integrity failed")
        names = set(archive.namelist())
        root = "Payload/Runner.app/"
        extension = root + "PlugIns/YinweiBroadcastUpload.appex/"
        bundles = []
        for prefix in [root, extension]:
            info = plistlib.loads(archive.read(prefix + "Info.plist"))
            executable = info["CFBundleExecutable"]
            if "/" in executable or "\\" in executable:
                raise ValueError("Unexpected executable path")
            binary = archive.read(prefix + executable)
            groups, has_signature = signature_groups(binary)
            profile_name = prefix + "embedded.mobileprovision"
            authorized = False
            if profile_name in names:
                # CMS payload is inspected in memory; never emit/extract it.
                profile = archive.read(profile_name)
                start = profile.find(b"<?xml")
                end = profile.find(b"</plist>", start)
                if start >= 0 and end >= 0:
                    values = plistlib.loads(profile[start:end + 8])
                    authorized = GROUP in values.get("Entitlements", {}).get(
                        "com.apple.security.application-groups", [])
            bundles.append({
                "bundleIdentifier": info["CFBundleIdentifier"],
                "executablePresent": bool(binary),
                "arm64DeviceMachO": binary[:4] == b"\xcf\xfa\xed\xfe"
                    and struct.unpack_from("<I", binary, 4)[0] == 0x0100000C,
                "signatureContainerPresent": has_signature,
                "dedicatedGroupInEntitlements": GROUP in groups,
                "embeddedProfilePresent": profile_name in names,
                "dedicatedGroupInProfile": authorized,
                "extensionPrincipalClass": info.get("NSExtension", {}).get(
                    "NSExtensionPrincipalClass"),
            })
        parent, child = bundles
        if not all(b["arm64DeviceMachO"] for b in bundles):
            raise ValueError("Expected two arm64 device executables")
        if not child["bundleIdentifier"].startswith(parent["bundleIdentifier"] + "."):
            raise ValueError("Invalid host/extension identifier relationship")
        if not str(child["extensionPrincipalClass"]).endswith(".SampleHandler"):
            raise ValueError("Broadcast extension principal class missing")
        return {
            "sha256": digest.hexdigest(), "zipIntegrity": True,
            "bundles": bundles,
            "liveCapabilityMetadataCompatible": all(
                b["dedicatedGroupInEntitlements"] and b["dedicatedGroupInProfile"]
                for b in bundles),
            "cryptographicSigningValidated": False,
            "actualIPadAcceptance": "pending",
        }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa")
    args = parser.parse_args()
    print(json.dumps(inspect(args.ipa), indent=2))
