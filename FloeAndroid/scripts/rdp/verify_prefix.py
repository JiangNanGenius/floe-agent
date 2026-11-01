#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Verify the materialized Android ARM64 FreeRDP/OpenSSL static prefix.

Checks the exact public headers, the two FreeRDP core archives, the OpenSSL
static archives, ELF/archive architecture, required symbols and the absence of
Apple binaries. Writes a deterministic manifest next to the prefix so the
SwiftPM integration can be audited without rebuilding.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

REQUIRED_HEADERS = [
    "freerdp/freerdp.h",
    "freerdp/gdi/gdi.h",
    "freerdp/input.h",
    "freerdp/settings.h",
    "freerdp/update.h",
    "freerdp/version.h",
    "winpr/synch.h",
]
REQUIRED_LIBRARIES = [
    "libfreerdp3.a",
    "libwinpr3.a",
    "libssl.a",
    "libcrypto.a",
]
REQUIRED_SYMBOLS = [
    "freerdp_connect",
    "freerdp_input_send_mouse_event",
    "freerdp_input_send_keyboard_event",
    "freerdp_input_send_unicode_keyboard_event",
]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: list[str]) -> str:
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"command failed: {' '.join(command)}\n{result.stderr}")
    return result.stdout


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prefix", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    prefix = args.prefix
    if not prefix.is_absolute() or not prefix.is_dir():
        raise SystemExit("prefix must be an absolute existing directory")

    missing = [header for header in REQUIRED_HEADERS if not (prefix / "include" / header).is_file()]
    if missing:
        raise SystemExit(f"missing headers: {', '.join(missing)}")
    missing = [library for library in REQUIRED_LIBRARIES if not (prefix / "lib" / library).is_file()]
    if missing:
        raise SystemExit(f"missing libraries: {', '.join(missing)}")

    forbidden = list(prefix.rglob("*.dylib")) + list(prefix.rglob("*.framework"))
    if forbidden:
        raise SystemExit(f"Apple binaries are not allowed: {forbidden[:4]}")
    if (prefix / "lib" / "libfreerdp-client3.a").exists():
        raise SystemExit("client library must not be linked into the Floe core")

    file_tool = shutil.which("file")
    if file_tool is None:
        raise SystemExit("the `file` utility is required for architecture proof")
    for library in REQUIRED_LIBRARIES:
        description = run([file_tool, str(prefix / "lib" / library)])
        if "archive" not in description.lower():
            raise SystemExit(f"{library} is not a static archive: {description.strip()}")
        if "aarch64" not in description.lower() and "arm aarch64" not in description.lower():
            raise SystemExit(f"{library} is not ARM64: {description.strip()}")

    nm = shutil.which("llvm-nm") or shutil.which("nm")
    if nm is None:
        raise SystemExit("llvm-nm/nm is required for symbol proof")
    symbols = run([nm, "-g", str(prefix / "lib" / "libfreerdp3.a")])
    absent = [symbol for symbol in REQUIRED_SYMBOLS if symbol not in symbols]
    if absent:
        raise SystemExit(f"missing FreeRDP symbols: {', '.join(absent)}")

    manifest = {
        "schema": 1,
        "abi": "arm64-v8a",
        "headers": {header: sha256(prefix / "include" / header) for header in REQUIRED_HEADERS},
        "libraries": {
            library: {
                "sha256": sha256(prefix / "lib" / library),
                "bytes": (prefix / "lib" / library).stat().st_size,
            }
            for library in REQUIRED_LIBRARIES
        },
    }
    output = args.output or prefix / "FLOE_RDP_PREFIX_MANIFEST.json"
    output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"verified {prefix} -> {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
