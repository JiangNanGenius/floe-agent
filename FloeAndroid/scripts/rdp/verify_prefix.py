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
import re
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

    header_paths = {
        header: prefix / "include" / ("winpr3" if header.startswith("winpr/") else "freerdp3") / header
        for header in REQUIRED_HEADERS
    }
    library_paths = {
        name: prefix / ("openssl/lib" if name in ("libssl.a", "libcrypto.a") else "lib") / name
        for name in REQUIRED_LIBRARIES
    }
    missing = [header for header, path in header_paths.items() if not path.is_file()]
    if missing:
        raise SystemExit(f"missing headers: {', '.join(missing)}")
    missing = [library for library, path in library_paths.items() if not path.is_file()]
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
    readobj = shutil.which("llvm-readobj")
    if readobj is None:
        raise SystemExit("NDK llvm-readobj is required for archive-member architecture proof")
    for library in REQUIRED_LIBRARIES:
        description = run([file_tool, str(library_paths[library])])
        if "archive" not in description.lower():
            raise SystemExit(f"{library} is not a static archive: {description.strip()}")
        headers = run([readobj, "--file-headers", str(library_paths[library])])
        machines = re.findall(r"Machine:\s+([^\n]+)", headers)
        if not machines or any(not machine.startswith("EM_AARCH64 ") for machine in machines):
            raise SystemExit(f"{library} contains missing or non-ARM64 ELF member headers")

    nm = shutil.which("llvm-nm") or shutil.which("nm")
    if nm is None:
        raise SystemExit("llvm-nm/nm is required for symbol proof")
    symbols = run([nm, "-g", str(prefix / "lib" / "libfreerdp3.a")])
    absent = [symbol for symbol in REQUIRED_SYMBOLS
              if re.search(r"\b[TW]\s+" + re.escape(symbol) + r"\b", symbols) is None]
    if absent:
        raise SystemExit(f"missing FreeRDP symbols: {', '.join(absent)}")

    manifest = {
        "schema": 1,
        "abi": "arm64-v8a",
        "headers": {header: sha256(header_paths[header]) for header in REQUIRED_HEADERS},
        "libraries": {
            library: {
                "sha256": sha256(library_paths[library]),
                "bytes": library_paths[library].stat().st_size,
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
