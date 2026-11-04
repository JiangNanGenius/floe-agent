#!/usr/bin/env python3
"""Read-only verification of the pinned engine source and App wiring."""
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    root = Path(__file__).resolve().parents[1]
    record = json.loads((root / "PROVENANCE.json").read_text())
    assert record["schemaVersion"] == 1
    assert record["capabilities"]["nativeJIT"] is False
    assert record["capabilities"]["liveMachines"] == 1
    files = record["files"]
    assert len({item["path"] for item in files}) == len(files)
    pinned = set()
    for item in files:
        relative = Path(item["path"])
        assert not relative.is_absolute() and ".." not in relative.parts
        path = root / relative
        assert path.is_file() and not path.is_symlink(), relative
        assert hashlib.sha256(path.read_bytes()).hexdigest() == item["sha256"], relative
        pinned.add(relative.as_posix())
    assert len(record["productionTranslationUnits"]) == 30
    assert set(record["productionTranslationUnits"]).issubset(pinned)
    for name in ("Source/LICENSE", "Source/NOTICE", "Bridge/MPL-2.0.txt"):
        assert (root / name).is_file(), name
    package = (root.parents[1] / "Package.swift").read_text()
    assert 'name: "FloeARM64Engine"' in package
    assert '"FloeTinyEMU"' not in package
    assert not (root.parent / "TinyEMU").exists()
    subprocess.run(["python3", str(root / "Tools/generate_crc32_tables.py"), "--check"], check=True)
    print("ARM64 provenance, 30 translation units, licenses and App wiring verified")


if __name__ == "__main__":
    main()
