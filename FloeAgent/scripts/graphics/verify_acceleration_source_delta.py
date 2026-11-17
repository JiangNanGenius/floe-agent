#!/usr/bin/env python3
"""Read-only validation of a candidate delta against its immutable source lock."""
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
DELTA = ROOT / "FloeAgent/LinuxGuest/image/graphics/ACCELERATION-SOURCE-DELTA-20261117.json"


def fingerprint(path):
    data = path.read_bytes()
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def main():
    errors = []
    delta = json.loads(DELTA.read_text())
    base = ROOT / delta["baseLock"]["path"]
    if fingerprint(base)["sha256"] != delta["baseLock"]["sha256"]:
        errors.append("immutable base lock digest mismatch")
    lock = json.loads(base.read_text())
    selected = {}
    for entry in delta["changes"]:
        name = entry["path"]
        if name in selected:
            errors.append(f"duplicate delta: {name}")
        selected[name] = entry
    locked = set()
    for entry in lock["files"]:
        name = entry["path"]
        if name in locked:
            errors.append(f"duplicate base entry: {name}")
        locked.add(name)
        original = {"bytes": entry["bytes"], "sha256": entry["sha256"]}
        change = selected.get(name)
        if change and change["previous"] != original:
            errors.append(f"delta does not match base: {name}")
        expected = change["current"] if change else original
        path = ROOT / name
        if not path.is_file() or fingerprint(path) != expected:
            errors.append(f"source bytes differ: {name}")
    for name in selected.keys() - locked:
        errors.append(f"delta has no base entry: {name}")
    for entry in delta["additionalInputs"]:
        path = ROOT / entry["path"]
        expected = {"bytes": entry["bytes"], "sha256": entry["sha256"]}
        if not path.is_file() or fingerprint(path) != expected:
            errors.append(f"additional input differs: {entry['path']}")
    print(json.dumps({"status": "failed" if errors else "passed",
                      "lockedSources": len(locked), "deltaSources": len(selected),
                      "additionalInputs": len(delta["additionalInputs"]),
                      "errors": errors}, indent=2))
    return bool(errors)


if __name__ == "__main__":
    sys.exit(main())
