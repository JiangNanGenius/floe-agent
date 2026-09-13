#!/usr/bin/env python3
"""Normalize the build 156 distribution bundle before signing.

The source archives remain pinned and untouched. Only reviewed non-iOS pnpm
addons and the libssh2 1.11.0 packaging defects are addressed here. Unknown
executables, changed addon bytes, or other malformed bundle metadata fail.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import stat
import struct
import subprocess

ADDONS = {
    "NodeTools/pnpm/dist/reflink.darwin-arm64-MYEHQQCP.node": "ddf457202f296ba0e8b1749e3066ada08f9c5a543369d3a9467786ff1516bfe0",
    "NodeTools/pnpm/dist/reflink.darwin-x64-CDTBYYIZ.node": "77231e00dfff9edfe476af2a30404740c0a44b14845445c1ed8594e2758f8875",
    "NodeTools/pnpm/dist/reflink.win32-arm64-msvc-IYGSKCGJ.node": "6e2597d13f461fb697303fb27308ef2ab29afe1e793523d6b40ca7644f84daa3",
    "NodeTools/pnpm/dist/reflink.win32-x64-msvc-5E6AAURT.node": "92cf1e61db1c58de603d228717dd32362da45f63ae32fe0b75bed4135132d65d",
    "NodeTools/pnpm/dist/vendor/fastlist-0.3.0-x86.exe": "017411f3b0b5c0402cc3b2cb87c32c6fc71abd82e5b17ea6108990096c75a65d",
    "NodeTools/pnpm/dist/vendor/fastlist-0.3.0-x64.exe": "d1a71f9ac1728082c1b276392725c3e010b98714888579b99152e401abedbf11",
}
SSH = "Frameworks/libssh2.framework"
MACHO = {bytes.fromhex(v) for v in ("cffaedfe", "cefaedfe", "feedfacf", "feedface", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def arm64_slice(data):
    """Return the existing generic arm64 slice, without rewriting its bytes."""
    magic = data[:4]
    if magic == bytes.fromhex("cffaedfe"):
        cpu, subtype = struct.unpack_from("<II", data, 4)
        if cpu != 0x100000C or subtype & 0xFFFFFF != 0:
            raise ValueError("Expected generic arm64 Mach-O")
        return data
    if magic not in (bytes.fromhex("cafebabe"), bytes.fromhex("cafebabf")):
        raise ValueError("Unsupported universal Mach-O format")
    count = struct.unpack_from(">I", data, 4)[0]
    wide = magic == bytes.fromhex("cafebabf")
    width = 32 if wide else 20
    if not 1 <= count <= 16 or len(data) < 8 + count * width:
        raise ValueError("Invalid universal Mach-O table")
    result = None
    for i in range(count):
        fields = struct.unpack_from(">IIQQII" if wide else ">IIIII", data, 8 + i * width)
        cpu, subtype, offset, size = fields[:4]
        if offset < 8 + count * width or offset + size > len(data):
            raise ValueError("Universal Mach-O slice exceeds file bounds")
        if cpu == 0x100000C and subtype & 0xFFFFFF == 0:
            if result is not None:
                raise ValueError("Duplicate arm64 slice")
            result = data[offset:offset + size]
    if result is None:
        raise ValueError("Missing generic arm64 slice")
    return result


def normalize(app, report_path, *, addon_hashes=ADDONS):
    app = Path(app).resolve()
    if app.suffix != ".app" or not app.is_dir():
        raise ValueError("Expected an existing application bundle")
    removals = []
    for relative, expected in addon_hashes.items():
        p = app / relative
        if p.exists():
            if p.is_symlink() or sha(p.read_bytes()) != expected:
                raise ValueError(f"Unreviewed addon bytes: {relative}")
            removals.append(p)

    # Validate all metadata and native resource locations before making changes.
    executables = set()
    ssh_plist = None
    ssh_info = None
    for p in app.rglob("Info.plist"):
        if p.parent.suffix not in (".app", ".appex", ".framework"):
            continue
        info = plistlib.loads(p.read_bytes())
        name = info.get("CFBundleExecutable")
        if not isinstance(name, str) or not name or Path(name).name != name:
            raise ValueError(f"Invalid bundle executable: {p.relative_to(app)}")
        executable = p.parent / name
        if not executable.is_file() or executable.is_symlink():
            raise ValueError(f"Missing bundle executable: {p.relative_to(app)}")
        executables.add(executable)
        minimum = info.get("MinimumOSVersion")
        if p.parent == app / SSH:
            if info.get("CFBundleShortVersionString") != "1.11.0" or info.get("CFBundleIdentifier") != "org.libssh2":
                raise ValueError("libssh2 package changed; review normalization policy")
            ssh_plist, ssh_info = p, info
            if minimum == "ios_version_min":
                continue
        if not isinstance(minimum, str) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", minimum):
            raise ValueError(f"Invalid MinimumOSVersion: {p.relative_to(app)}")
    for p in app.rglob("*"):
        if not p.is_file() or p in executables or p in removals:
            continue
        with p.open("rb") as f:
            magic = f.read(4)
        # Mach-O is loadable Apple code. Foreign-format supplier data (such as
        # pip's Windows script templates) is not an Apple executable and must
        # not be removed by a broad file-extension rule.
        if magic in MACHO:
            raise ValueError(f"Standalone native binary: {p.relative_to(app)}")

    ssh_change = None
    if ssh_plist is not None:
        binary = ssh_plist.parent / ssh_info["CFBundleExecutable"]
        original = binary.read_bytes()
        active = arm64_slice(original)
        build = subprocess.check_output(["xcrun", "vtool", "-arch", "arm64", "-show-build", str(binary)], text=True)
        if (re.findall(r"^\s*platform\s+(\S+)", build, re.M) != ["IOS"]
                or re.findall(r"^\s*minos\s+(\S+)", build, re.M) != ["14.0"]
                or re.findall(r"^\s*sdk\s+(\S+)", build, re.M) != ["16.2"]):
            raise ValueError("Unexpected libssh2 load commands; do not invent SDK metadata")
        arches = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
        if set(arches) not in ({"arm64"}, {"arm64", "arm64e"}):
            raise ValueError(f"Unexpected libssh2 architectures: {arches}")
        if ssh_info["MinimumOSVersion"] not in ("ios_version_min", "14.0"):
            raise ValueError("Unexpected libssh2 minimum OS")
        ssh_change = {"path": SSH, "arm64_sha256": sha(active), "architectures_before": arches,
                      "architectures_after": ["arm64"], "minimum_os_before": ssh_info["MinimumOSVersion"],
                      "minimum_os_after": "14.0", "recorded_sdk_unchanged": "16.2"}
        # Write the already-existing slice directly: exact bytes, no relinking
        # or SDK spoofing. Signing happens only after this transformation.
        if original != active:
            temporary = binary.with_name(binary.name + ".arm64-stage")
            temporary.write_bytes(active)
            temporary.chmod(stat.S_IMODE(binary.stat().st_mode))
            temporary.replace(binary)
        if sha(binary.read_bytes()) != sha(active):
            raise ValueError("arm64 content changed during normalization")
        if subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split() != ["arm64"]:
            raise ValueError("Unexpected normalized architecture")
        ssh_info["MinimumOSVersion"] = "14.0"
        ssh_plist.write_bytes(plistlib.dumps(ssh_info))
    for p in removals:
        p.unlink()
    report = {"policy": "build156-app-store-bundle-v1", "removed_non_ios_addons": [str(p.relative_to(app)) for p in removals],
              "libssh2": ssh_change, "validated_bundle_executables": len(executables)}
    Path(report_path).write_text(json.dumps(report, indent=2) + "\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--report", required=True)
    args = parser.parse_args()
    print(json.dumps(normalize(args.app, args.report), indent=2))
