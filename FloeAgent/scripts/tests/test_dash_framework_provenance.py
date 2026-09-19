#!/usr/bin/env python3
"""Verify (or record) that Frameworks/dash*.xcframework matches the tracked
DashIOS sources.

The app links dash*.xcframework, which is git-ignored and produced by
scripts/build_dash_ios.sh from ThirdParty/DashIOS. A source-only change (for
example the interactive-stdin fix in src/input.c) therefore reaches a release
only when the frameworks are actually rebuilt from that source. This script
makes that chain hash-verifiable:

  * build_dash_ios.sh finishes by running this script with --write, recording
    a manifest with the sha256 of every DashIOS source input and of every
    built framework binary;
  * release CI runs it without arguments (check mode) after bootstrapping the
    runtime, and fails the build when the frameworks in the tree were not
    built from the tracked source (or are missing).

Check mode is read-only. The manifest itself lives in the git-ignored
Frameworks directory next to the binaries it describes.
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

MANIFEST_NAME = "dash-build-manifest.json"
GENERATOR = "floe-dash-provenance-v1"
FRAMEWORK_NAMES = ["dash", "dashA", "dashB", "dashC", "dashD", "dashE"]
SLICES = ["ios-arm64", "ios-arm64_x86_64-simulator"]
IGNORED_FILES = {".DS_Store"}
# Only the files that actually feed the build (see scripts/build_dash_ios.sh):
# the whole src/ tree plus the autotools inputs and framework plist templates.
# Docs (PROVENANCE.md, COPYING) are deliberately excluded so a documentation
# edit does not force a framework rebuild.
ROOT_INPUT_FILES = (
    "Makefile.am",
    "Makefile.in",
    "aclocal.m4",
    "basic_Info.plist",
    "basic_Info_Simulator.plist",
    "config.h.in",
    "configure",
    "configure.ac",
    "histedit.h",
    "ios_error.h",
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_inputs(source_dir: Path) -> dict:
    """Hash the DashIOS build inputs, sorted by relative path."""
    files = {}
    candidates = [source_dir / name for name in ROOT_INPUT_FILES]
    candidates += sorted((source_dir / "src").rglob("*")) if (source_dir / "src").is_dir() else []
    for path in sorted(candidates):
        if not path.is_file() or path.name in IGNORED_FILES:
            continue
        relative = path.relative_to(source_dir).as_posix()
        files[relative] = sha256_file(path)
    combined = hashlib.sha256()
    for relative, digest in files.items():
        combined.update(relative.encode("utf-8"))
        combined.update(b"\0")
        combined.update(digest.encode("ascii"))
        combined.update(b"\0")
    return {
        "files": files,
        "file_count": len(files),
        "source_sha256": combined.hexdigest(),
    }


def binary_inputs(frameworks_dir: Path) -> dict:
    binaries = {}
    for name in FRAMEWORK_NAMES:
        for slice_name in SLICES:
            binary = frameworks_dir / f"{name}.xcframework" / slice_name / f"{name}.framework" / name
            key = f"{name}/{slice_name}"
            if not binary.is_file():
                raise FileNotFoundError(f"missing built dash binary: {binary}")
            binaries[key] = sha256_file(binary)
    return binaries


def build_manifest(source_dir: Path, frameworks_dir: Path) -> dict:
    return {
        "generator": GENERATOR,
        "source": source_inputs(source_dir),
        "binaries": binary_inputs(frameworks_dir),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true",
                        help="record the manifest (used by build_dash_ios.sh)")
    parser.add_argument("--source-dir", type=Path,
                        default=Path(__file__).resolve().parents[2] / "ThirdParty" / "DashIOS")
    parser.add_argument("--frameworks-dir", type=Path,
                        default=Path(__file__).resolve().parents[2] / "Frameworks")
    args = parser.parse_args()

    if not args.source_dir.is_dir():
        print(f"DashIOS source directory not found: {args.source_dir}", file=sys.stderr)
        return 2

    manifest_path = args.frameworks_dir / MANIFEST_NAME

    if args.write:
        manifest = build_manifest(args.source_dir, args.frameworks_dir)
        args.frameworks_dir.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        print(f"wrote {manifest_path} ({manifest['source']['file_count']} source files, "
              f"{len(manifest['binaries'])} binaries, source {manifest['source']['source_sha256'][:16]}…)")
        return 0

    if not manifest_path.is_file():
        print(f"{manifest_path} is missing: build the dash frameworks with "
              f"scripts/build_dash_ios.sh (release tooling bootstrap) before checking provenance.",
              file=sys.stderr)
        return 1
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("generator") != GENERATOR:
        print(f"{manifest_path} has an unknown generator {manifest.get('generator')!r}; "
              f"rebuild the dash frameworks.", file=sys.stderr)
        return 1

    problems = []
    recorded_sources = manifest.get("source", {})
    current_sources = source_inputs(args.source_dir)
    if recorded_sources.get("source_sha256") != current_sources["source_sha256"]:
        stale = sorted(
            relative for relative, digest in current_sources["files"].items()
            if recorded_sources.get("files", {}).get(relative) != digest
        )
        added = sorted(set(current_sources["files"]) - set(recorded_sources.get("files", {})))
        removed = sorted(set(recorded_sources.get("files", {})) - set(current_sources["files"]))
        problems.append(
            "DashIOS sources changed after the frameworks were built "
            f"(changed={stale[:5]}{'…' if len(stale) > 5 else ''} added={added[:5]} removed={removed[:5]}); "
            "re-run scripts/build_dash_ios.sh so the interactive-stdin and any other "
            "DashIOS source changes are actually compiled into the app inputs.")

    recorded_binaries = manifest.get("binaries", {})
    try:
        current_binaries = binary_inputs(args.frameworks_dir)
    except FileNotFoundError as error:
        problems.append(f"{error}; the app cannot link without the rebuilt frameworks.")
    else:
        mismatched = sorted(
            key for key, digest in current_binaries.items()
            if recorded_binaries.get(key) != digest
        )
        missing = sorted(set(recorded_binaries) - set(current_binaries))
        if mismatched or missing:
            problems.append(
                f"dash framework binaries do not match the recorded manifest "
                f"(mismatched={mismatched[:4]}{'…' if len(mismatched) > 4 else ''} missing={missing[:4]}); "
                "re-run scripts/build_dash_ios.sh.")

    if problems:
        for problem in problems:
            print(f"FAIL  {problem}", file=sys.stderr)
        return 1

    print(f"PASS  dash framework provenance: {current_sources['file_count']} source files "
          f"(sha256 {current_sources['source_sha256'][:16]}…) match {len(current_binaries)} built binaries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
