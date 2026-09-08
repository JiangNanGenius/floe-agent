#!/usr/bin/env python3
"""Repair known packaging-only defects in a SHA-locked Office bundle."""
import argparse
import json
import os
from pathlib import Path
import tarfile
from package_office_engine import digest
from prepare_office_native_sources import DEFAULT_LOCK
from verify_office_engine import contained, verify


def repair(archive_path, destination, lock_path=DEFAULT_LOCK):
    archive_path, destination = Path(archive_path).resolve(), Path(destination).resolve()
    lock = json.loads(Path(lock_path).read_text())["qualifiedEmbeddingArtifact"]
    if digest(archive_path) != lock["archiveSHA256"]:
        raise ValueError("Complete input archive differs from locked qualification")
    if destination.exists():
        raise ValueError("Use a new destination; preserve previously extracted inputs")
    destination.mkdir(parents=True)
    with tarfile.open(archive_path) as archive:
        archive.extractall(destination, filter="data")
    manifest_path = destination / "bundle-manifest.json"
    manifest_hash = digest(manifest_path)
    manifest = json.loads(manifest_path.read_text())
    aliases = lock["omittedTestAliases"]
    removed = []
    kept = []
    for entry in manifest["files"]:
        name = entry["path"]
        if name not in aliases:
            kept.append(entry)
            continue
        path = contained(destination, name)
        if entry != {"path": name, "symlink": aliases[name]} or not path.is_symlink() or os.readlink(path) != aliases[name] or path.exists():
            raise ValueError("Known unused alias does not match the locked defect")
        removed.append(entry)
    if len(removed) != len(aliases) or any(name in manifest["linkerInputs"] for name in aliases):
        raise ValueError("Unexpected alias or native linker manifest")
    for entry in removed:
        contained(destination, entry["path"]).unlink()
    restored = lock.get("restoredEmptyDirectories", [])
    for name in restored:
        path = contained(destination, name)
        if path.exists() or path.is_symlink() or any(entry["path"] == name for entry in manifest["files"]):
            raise ValueError("Expected omitted empty resource directory")
        path.mkdir(parents=True)
        kept.append({"path": name, "directory": True})
    manifest["files"] = kept
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    checked = verify(destination, prepare=True)
    report = {"originalArchiveSHA256": lock["archiveSHA256"],
              "originalManifestSHA256": manifest_hash, "removedUnusedTestAliases": removed,
              "restoredEmptyDirectories": restored,
              "verified": checked, "nativeCompilePassed": False, "deviceRoundtripPassed": False}
    (destination / "bundle-repair.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    print(json.dumps(repair(args.archive, args.destination), indent=2))
