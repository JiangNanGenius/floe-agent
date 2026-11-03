#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Fetch and verify the pinned FreeRDP/OpenSSL release tarballs.

This script never builds anything. It downloads the two exact upstream
releases named by runtime.lock.json into a caller-supplied scratch directory,
checks the published SHA-256 before extraction, and refuses to reuse an
already-extracted tree whose archive hash differs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import tarfile
import urllib.request
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch(name: str, source: str, expected: str, root: Path) -> Path:
    archive = root / f"{name}.tar.gz"
    if archive.exists():
        actual = sha256(archive)
        if actual != expected:
            raise SystemExit(f"{archive}: sha256 {actual} != pinned {expected}")
        return archive
    request = urllib.request.Request(source, headers={"User-Agent": "floe-rdp-pin/1"})
    with urllib.request.urlopen(request, timeout=180) as response:
        data = response.read()
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        raise SystemExit(f"{source}: sha256 {actual} != pinned {expected}")
    archive.write_bytes(data)
    return archive


def main() -> int:
    if sys.version_info < (3, 12):
        raise SystemExit("Python 3.12 or newer is required for filtered archive extraction.")
    parser = argparse.ArgumentParser()
    parser.add_argument("--scratch", required=True, type=Path)
    parser.add_argument("--lock", type=Path, default=Path(__file__).with_name("runtime.lock.json"))
    args = parser.parse_args()
    lock = json.loads(args.lock.read_text())
    args.scratch.mkdir(parents=True, exist_ok=True)

    for key in ("freerdp", "openssl"):
        entry = lock[key]
        archive = fetch(key, entry["source"], entry["sha256"], args.scratch)
        extracted = args.scratch / f"{key}-{entry['version']}"
        if not extracted.exists():
            with tarfile.open(archive) as tar:
                tar.extractall(args.scratch, filter="data")
        marker = args.scratch / f".{key}.verified"
        marker.write_text(entry["sha256"] + "\n")
        print(f"{key} {entry['version']} sha256={entry['sha256']} ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
