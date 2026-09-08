#!/usr/bin/env python3
"""Preserve qualified build inputs for embedding, without certifying the app."""
import json
import os
from pathlib import Path
import tarfile

root = Path(os.environ["FLOE_OFFICE_BUILD_ROOT"]).resolve()
report = json.loads((root / "qualification.json").read_text())
if not report.get("nativeBuildPassed"):
    raise SystemExit("Cannot package an unqualified native build")
source = root / "source"
paths = set()
for subtree in ("ios", "browser", "include", "engine/instdir", "engine/include",
                "engine/workdir/CustomTarget/ios"):
    directory = source / subtree
    if directory.exists():
        for path in directory.rglob("*"):
            if not path.is_dir() and not {"node_modules", ".git"}.intersection(path.parts):
                paths.add(path)
paths.update((source / "engine").rglob("*.a"))
for pattern in ("COPYING*", "LICENSE*", "NOTICE*"):
    paths.update(source.glob(pattern))
    paths.update((source / "engine").glob(pattern))
if not any(path.suffix == ".a" for path in paths):
    raise SystemExit("Native archives missing")
destination = root / "office-engine-ios-arm64.tar.gz"
temporary = destination.with_suffix(".partial")
try:
    with tarfile.open(temporary, "w:gz", compresslevel=3, dereference=False) as archive:
        archive.add(root / "qualification.json", arcname="qualification.json")
        for path in sorted(paths):
            archive.add(path, arcname=str(path.relative_to(root)), recursive=False)
    temporary.replace(destination)
except BaseException:
    temporary.unlink(missing_ok=True)
    raise
print(f"Packaged {len(paths)} build files; embedding and device roundtrip remain unverified")
