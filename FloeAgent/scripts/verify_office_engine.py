#!/usr/bin/env python3
"""Verify a relocated Office bundle and prepare its ordered native linker list."""
import argparse
import json
import os
from pathlib import Path
from package_office_engine import digest


def contained(root, name):
    relative = Path(name)
    if relative.is_absolute() or ".." in relative.parts or not relative.parts:
        raise ValueError(f"Invalid bundle path: {name}")
    path = root / relative
    if not path.resolve().is_relative_to(root):
        raise ValueError(f"Bundle path escapes root: {name}")
    return path


def verify(root, prepare=False):
    root = Path(root).resolve()
    manifest = json.loads((root / "bundle-manifest.json").read_text())
    if manifest.get("formatVersion") != 2:
        raise ValueError("Bundle lacks the complete, relocatable build-input manifest")
    seen = set()
    for entry in manifest["files"]:
        name = entry["path"]
        if name in seen:
            raise ValueError(f"Duplicate bundle entry: {name}")
        seen.add(name)
        path = contained(root, name)
        if "symlink" in entry:
            if not path.is_symlink() or os.readlink(path) != entry["symlink"] or not path.exists():
                raise ValueError(f"Changed or dangling symlink: {name}")
            if Path(entry["symlink"]).is_absolute():
                raise ValueError(f"Non-portable symlink: {name}")
        elif entry.get("directory") is True:
            if path.is_symlink() or not path.is_dir():
                raise ValueError(f"Changed or missing directory: {name}")
        elif path.is_symlink() or not path.is_file() or path.stat().st_size != entry["size"] or digest(path) != entry["sha256"]:
            raise ValueError(f"Changed or missing file: {name}")
    inputs = manifest.get("linkerInputs", manifest["linkerArchives"])
    if not inputs:
        raise ValueError("Empty linker list")
    for name in inputs:
        if name not in seen or contained(root, name).suffix not in {".a", ".o"}:
            raise ValueError(f"Linker input not covered by manifest: {name}")
    if prepare:
        output = root / "prepared"
        if output.is_symlink():
            raise ValueError("Preparation directory cannot be a symlink")
        output.mkdir(exist_ok=True)
        # Keep immutable original inputs for repeated integrity checks. Floe's
        # embedding target must consume this relocated list, not the old one.
        list_path = output / "ios-all-static-libs.list"
        temporary = output / ".ios-all-static-libs.partial"
        if temporary.is_symlink() or list_path.is_symlink():
            raise ValueError("Preparation output cannot be a symlink")
        temporary.write_text("\n".join(str(contained(root, name)) for name in inputs) + "\n")
        temporary.replace(list_path)
    return {"filesVerified": len(seen), "archivesVerified": sum(name.endswith(".a") for name in inputs),
            "objectsVerified": sum(name.endswith(".o") for name in inputs), "linkerInputsVerified": len(inputs),
            "sourceCommit": manifest["sourceCommit"], "embeddingVerified": False,
            "deviceRoundtripVerified": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--prepare", action="store_true")
    arguments = parser.parse_args()
    print(json.dumps(verify(arguments.root, arguments.prepare), indent=2))
