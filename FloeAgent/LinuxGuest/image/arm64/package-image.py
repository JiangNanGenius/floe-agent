#!/usr/bin/env python3
"""Verify and package an existing clean ARM64 image; never boot or alter it."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile


def sha512(path):
    value = hashlib.sha512()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(4 * 1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image-directory", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    root = args.image_directory.resolve(strict=True)
    manifest = json.loads((root / "manifest.json").read_text())
    artifacts = manifest["artifacts"]
    if not manifest.get("qualified") or not manifest.get("qualificationRun"):
        raise ValueError("Actual image qualification is required")
    if manifest.get("max_vcpus") != 4 or not manifest.get("smp_capable"):
        raise ValueError("Missing four-core qualification declaration")
    if {item["role"] for item in artifacts} != {"bios", "kernel", "initrd", "disk"}:
        raise ValueError("Unexpected or missing image roles")
    paths = []
    for item in artifacts:
        relative = Path(item["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Artifact path escapes the image")
        path = root / relative
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root):
            raise ValueError("Artifact must be an owned regular file")
        if path.stat().st_size != item["bytes"] or sha512(path) != item["sha512"]:
            raise ValueError("Artifact size or SHA-512 mismatch: " + str(relative))
        paths.append(path)
    if args.out.exists():
        raise ValueError("Refusing to overwrite an existing archive")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    staging = args.out.with_suffix(args.out.suffix + ".part")
    try:
        with zipfile.ZipFile(staging, "x", compression=zipfile.ZIP_DEFLATED,
                             compresslevel=1, allowZip64=True) as archive:
            for path in [root / "manifest.json"] + paths:
                archive.write(path, path.relative_to(root).as_posix())
        staging.replace(args.out)
    finally:
        staging.unlink(missing_ok=True)
    result = {"imageID": manifest["id"], "bytes": args.out.stat().st_size,
              "sha512": sha512(args.out)}
    args.out.with_suffix(args.out.suffix + ".json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
