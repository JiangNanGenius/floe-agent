#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Verify and prepare the pinned Mesa graphics sources.

This tool is deliberately small and offline. It never downloads an archive,
never writes outside its explicit --work-dir and never claims a compiler,
linker, GPU, VM or App result.

Default is a read-only check of the archive and every patch digest. With
--apply it extracts the archive into --work-dir and applies the selected
series there, then writes a receipt. The source tree passed to Meson is the
printed "tree" path.

Examples:
  python3 prepare_mesa_sources.py --series guest \
      --archive ~/Downloads/mesa_25.0.7.orig.tar.xz

  python3 prepare_mesa_sources.py --series host \
      --archive ~/Downloads/mesa-30da3918....tar.gz \
      --work-dir ~/Library/Caches/CodexBuild/FloeAgent/graphics/host-wsi \
      --apply
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import tarfile
from pathlib import Path
from typing import NoReturn

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
GRAPHICS = REPO / "LinuxGuest" / "image" / "graphics"
SELECTION = GRAPHICS / "SOURCE-SELECTION.json"
GUEST_PATCH = GRAPHICS / "patches" / "guest-mesa-25.0.7" / "0001-floe-x11-cpu-present-complete.patch"
HOST_SERIES = GRAPHICS / "patches" / "host-mesa-30da3918" / "SERIES.json"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fail(message: str) -> NoReturn:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def load_selection() -> dict:
    if not SELECTION.is_file():
        fail(f"missing source selection: {SELECTION}")
    return json.loads(SELECTION.read_text())


def expected_archive(selection: dict, series: str) -> dict:
    if series == "guest":
        return selection["streams"]["installedGuestMesa"]["origArchive"]
    return selection["streams"]["nextHostKosmicKrisp"]["sourceArchives"][0]


def series_patches(series: str) -> list[dict]:
    if series == "guest":
        return [{
            "order": 1,
            "file": GUEST_PATCH.name,
            "path": GUEST_PATCH,
            "sha256": sha256(GUEST_PATCH),
            "applyCwd": "",
        }]
    data = json.loads(HOST_SERIES.read_text())
    patches = []
    for entry in data["patches"]:
        path = HOST_SERIES.parent / entry["file"]
        patches.append({
            "order": entry["order"],
            "file": entry["file"],
            "path": path,
            "sha256": entry["sha256"],
            "applyCwd": entry.get("applyCwd", ""),
        })
    return patches


def verify_patches(patches: list[dict]) -> list[dict]:
    records = []
    for patch in patches:
        path = patch["path"]
        if not path.is_file():
            fail(f"missing patch: {path}")
        actual = sha256(path)
        if actual != patch["sha256"]:
            fail(f"patch digest mismatch: {path}\n  expected {patch['sha256']}\n  actual   {actual}")
        records.append({
            "order": patch["order"],
            "file": patch["file"],
            "sha256": actual,
            "bytes": path.stat().st_size,
            "applyCwd": patch["applyCwd"],
        })
    return records


def safe_extract(archive: Path, destination: Path) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    root = destination.resolve()
    with tarfile.open(archive, "r:*") as tar:
        for member in tar.getmembers():
            target = (destination / member.name).resolve()
            if root not in target.parents and target != root:
                fail(f"archive entry escapes destination: {member.name}")
            if member.issym() or member.islnk():
                link = (target.parent / member.linkname).resolve()
                if root not in link.parents and link != root:
                    fail(f"archive link escapes destination: {member.name}")
        tar.extractall(destination)
    entries = [p for p in destination.iterdir() if p.is_dir()]
    if len(entries) == 1:
        return entries[0]
    return destination


def patch_check(patch: Path, tree: Path, apply_cwd: str) -> subprocess.CompletedProcess:
    cwd = tree / apply_cwd if apply_cwd else tree
    return subprocess.run(
        ["/usr/bin/patch", "-p1", "-F", "0", "--batch", "--forward", "--dry-run", "-i", str(patch)],
        cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )


def patch_apply(patch: Path, tree: Path, apply_cwd: str) -> subprocess.CompletedProcess:
    cwd = tree / apply_cwd if apply_cwd else tree
    return subprocess.run(
        ["/usr/bin/patch", "-p1", "-F", "0", "--batch", "--forward", "-i", str(patch)],
        cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--series", choices=("guest", "host"), default="guest")
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path,
                        help="writable extraction target; required with --apply")
    parser.add_argument("--apply", action="store_true",
                        help="extract to --work-dir and apply the series; default is check-only")
    parser.add_argument("--receipt", type=Path,
                        help="optional JSON receipt path (default: <work-dir>/PREPARE_RECEIPT.json)")
    args = parser.parse_args()

    selection = load_selection()
    archive_spec = expected_archive(selection, args.series)
    archive = args.archive.expanduser().resolve()
    if not archive.is_file():
        fail(f"archive not found: {archive}")
    actual = sha256(archive)
    if actual != archive_spec["sha256"]:
        fail(f"archive digest mismatch for {archive.name}\n  expected {archive_spec['sha256']}\n  actual   {actual}")
    if archive.stat().st_size != archive_spec["bytes"]:
        fail(f"archive size mismatch: expected {archive_spec['bytes']}, actual {archive.stat().st_size}")

    patches = series_patches(args.series)
    records = verify_patches(patches)
    print(f"verified archive {archive.name} sha256={actual} bytes={archive.stat().st_size}")
    print(f"verified {len(records)} patch digests for series={args.series}")
    for record in records:
        print(f"  {record['order']:04d} {record['sha256'][:16]} {record['file']}")

    receipt = {
        "schema": "floe.mesa-source-preparation.v1",
        "series": args.series,
        "archive": {"path": str(archive), "sha256": actual, "bytes": archive.stat().st_size},
        "patches": records,
        "applyRequested": args.apply,
        "compilerOrLinkerInvoked": False,
        "gpuOrVmExecuted": False,
    }

    if not args.apply:
        receipt["status"] = "CHECKED_SOURCE_ONLY"
        receipt["tree"] = None
        print("check-only: no extraction or patch application performed")
        if args.receipt:
            args.receipt.parent.mkdir(parents=True, exist_ok=True)
            args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
        else:
            print(json.dumps({"status": receipt["status"], "patches": len(records)}, indent=2))
        return 0

    if args.work_dir is None:
        fail("--apply requires --work-dir")
    work = args.work_dir.expanduser().resolve()
    if work.exists():
        # Never mutate a directory the caller did not explicitly create for this run.
        fail(f"work directory already exists; choose a fresh path: {work}")
    work.mkdir(parents=True)
    extract_dir = work / "archive"
    tree = safe_extract(archive, extract_dir)

    applied = []
    for patch, record in zip(patches, records):
        check = patch_check(patch["path"], tree, patch["applyCwd"])
        if check.returncode != 0:
            fail(f"patch {patch['file']} does not apply cleanly:\n{check.stdout}")
        result = patch_apply(patch["path"], tree, patch["applyCwd"])
        if result.returncode != 0:
            fail(f"patch {patch['file']} failed:\n{result.stdout}")
        applied.append(record["file"])
        print(f"applied {record['order']:04d} {record['file']}")

    receipt.update({
        "status": "SOURCE_TREE_PATCHED_BUILD_UNRUN",
        "tree": str(tree),
        "applied": applied,
    })
    receipt_path = args.receipt or (work / "PREPARE_RECEIPT.json")
    receipt_path.parent.mkdir(parents=True, exist_ok=True)
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"tree={tree}")
    print(f"receipt={receipt_path}")
    print("No compiler, linker, GPU, VM or App command was run.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
