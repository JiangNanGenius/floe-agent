#!/usr/bin/env python3
"""Stage a verified helper into the Full APK source set.

Only the exact bytes covered by the manifest are copied. The manifest is the
same file the root server reads from the APK, so the App preflight, APK native
library and server-extracted executable all bind one SHA-256.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

PACKAGED_NAME = "libfloecapture_helper.so"
ASSET_PATH = "root-capture/helper.json"
REQUIRED_LICENSES = ("tcpdump-LICENSE", "libpcap-LICENSE", "SOURCES.md", "NOTICE.md")
GUARD_SCHEMA = "floe.capture-guard.v1"
GUARD_ABI = "arm64-v8a"
HEX64 = re.compile(r"^[0-9a-f]{64}$")


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(64 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_copy(source: str, destination: str, mode: int) -> None:
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    temporary = destination + ".tmp"
    shutil.copyfile(source, temporary)
    os.chmod(temporary, mode)
    with open(temporary, "rb") as handle:
        os.fsync(handle.fileno())
    os.replace(temporary, destination)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--manifest", required=True)
    args = parser.parse_args()

    repo = os.path.abspath(args.repo_root)
    if not os.path.isfile(os.path.join(repo, "app", "build.gradle.kts")):
        print("error: --repo-root is not the FloeAndroid source root", file=sys.stderr)
        return 2
    binary = os.path.abspath(args.binary)
    manifest_path = os.path.abspath(args.manifest)
    with open(manifest_path, "r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    required = ("schema", "id", "version", "abi", "minSdk", "pageSize",
                "packagedName", "sha256", "sizeBytes", "guard")
    for key in required:
        if key not in manifest:
            print(f"error: manifest missing {key}", file=sys.stderr)
            return 3
    guard = manifest.get("guard")
    if not isinstance(guard, dict):
        print("error: manifest guard binding is missing", file=sys.stderr)
        return 3
    if (guard.get("schema") != GUARD_SCHEMA or guard.get("abi") != GUARD_ABI or
            str(guard.get("version")) != "1"):
        print("error: manifest guard schema/version/ABI mismatch", file=sys.stderr)
        return 3
    for key in ("sourceSha256", "headerSha256", "patchSha256"):
        value = guard.get(key)
        if not isinstance(value, str) or not HEX64.match(value):
            print(f"error: manifest guard {key} is invalid", file=sys.stderr)
            return 3
    if manifest["schema"] != "floe.root-capture-helper.v2":
        print("error: manifest schema mismatch (guarded helper required)", file=sys.stderr)
        return 3
    if manifest["packagedName"] != PACKAGED_NAME:
        print("error: manifest packagedName mismatch", file=sys.stderr)
        return 3
    if manifest["sha256"] != sha256_file(binary):
        print("error: binary digest does not match manifest", file=sys.stderr)
        return 4
    if manifest["sizeBytes"] != os.path.getsize(binary):
        print("error: binary size does not match manifest", file=sys.stderr)
        return 4
    verify_script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "verify-helper.py")
    checked = subprocess.run(
        [sys.executable, verify_script, "--binary", binary,
         "--expect-sha", manifest["sha256"],
         "--guard-source", guard["sourceSha256"],
         "--guard-header", guard["headerSha256"],
         "--guard-patch", guard["patchSha256"]],
        check=False,
        capture_output=True,
        text=True,
    )
    if checked.returncode != 0:
        sys.stderr.write(checked.stderr)
        print("error: staged helper failed ELF verification", file=sys.stderr)
        return 5
    for license_name in REQUIRED_LICENSES:
        if not os.path.isfile(os.path.join(repo, "licenses", "root-capture", license_name)):
            print(f"error: missing license/notice: {license_name}", file=sys.stderr)
            return 6

    native = os.path.join(repo, "app", "src", "full", "jniLibs", "arm64-v8a", PACKAGED_NAME)
    asset = os.path.join(repo, "app", "src", "full", "assets", ASSET_PATH)
    atomic_copy(binary, native, 0o755)
    atomic_copy(manifest_path, asset, 0o644)
    legal_root = os.path.join(repo, "app", "src", "full", "assets", "legal", "root-capture")
    for license_name in REQUIRED_LICENSES:
        atomic_copy(
            os.path.join(repo, "licenses", "root-capture", license_name),
            os.path.join(legal_root, license_name),
            0o644,
        )
    if sha256_file(native) != manifest["sha256"]:
        print("error: staged native library digest mismatch", file=sys.stderr)
        return 7
    print(json.dumps({
        "native": native,
        "asset": asset,
        "legal": legal_root,
        "sha256": manifest["sha256"],
        "sizeBytes": manifest["sizeBytes"],
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
