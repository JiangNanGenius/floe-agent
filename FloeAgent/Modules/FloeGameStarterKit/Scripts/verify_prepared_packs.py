#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Verify the actual prepared Phaser/KAPLAY/Babylon/PlayCanvas packs.

Read-only. The packs are produced by the existing qualification/resource
pipeline; this script does not download, build or execute an engine.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "Sources/FloeGameStarterKit/Resources/Catalog/engines.json"
DEFAULT_ROOT = Path(__file__).resolve().parents[5] / (
    "Artifacts/game-predevelopment-expanded/authoring-starters/resource-packs")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    results = []
    failures = []
    for item in catalog["engines"]:
        if item["templateKind"] != "runtimePack":
            continue
        engine = item["engine"]
        pack = item["runtimePack"]
        directory = args.root / pack["id"]
        if not directory.is_dir():
            failures.append(f"{engine}: missing pack directory {directory}")
            continue
        files = []
        for file in pack["files"]:
            path = directory / file["path"]
            if not path.is_file():
                failures.append(f"{engine}: missing {file['path']}")
                continue
            data = path.read_bytes()
            digest = sha256(path)
            ok = len(data) == file["bytes"] and digest == file["sha256"]
            files.append({"path": file["path"], "bytes": len(data), "sha256": digest, "ok": ok})
            if not ok:
                failures.append(f"{engine}: hash/size mismatch {file['path']}")
        results.append({
            "engine": engine,
            "packID": pack["id"],
            "engineVersion": pack["engineVersion"],
            "license": pack["license"],
            "directory": str(directory),
            "files": files,
        })
    if any("3001.0.19" in item["packID"] for item in results):
        failures.append("KAPLAY 3001.0.19 must not be selected")
    output = {
        "result": "pass" if not failures else "fail",
        "root": str(args.root),
        "packs": results,
        "failures": failures,
    }
    text = json.dumps(output, indent=2, ensure_ascii=False) + "\n"
    print(text, end="")
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    raise SystemExit(0 if not failures else 1)


if __name__ == "__main__":
    main()
