#!/usr/bin/env python3
"""Verify (or record) that Frameworks/dash*.xcframework matches the tracked
DashIOS build inputs.

The app links dash*.xcframework, which is git-ignored and produced by
scripts/build_dash_ios.sh from ThirdParty/DashIOS. A source-only change (for
example the interactive-stdin fix in src/input.c) therefore reaches a release
only when the frameworks are actually rebuilt from that source. This script
makes that chain hash-verifiable:

  * build_dash_ios.sh finishes by running this script with --write, recording
    a manifest with the sha256 of every build input and of every built
    framework binary;
  * release CI runs it without arguments (check mode) after bootstrapping the
    runtime, and fails the build when the frameworks in the tree were not
    built from the tracked inputs (or are missing).

Build inputs are the non-documentation files under ThirdParty/DashIOS
(compiled sources and headers, generated-code inputs, autotools configuration
and the framework plist templates), the build script itself, and the
FloeShellEngine package manifest that pins the linked ios_system artifact by
URL and checksum. Documentation (COPYING, PROVENANCE.md, READMEs, *.md and man
pages such as src/dash.1) cannot reach the compiler or linker, so a
documentation-only edit must not invalidate a binary: documentation is
excluded when the manifest is written and ignored when it is read, including
in manifests recorded before this classification existed. Compiled sources,
build configuration and the linked-engine pin all stay fail-closed.

Check mode is read-only. The manifest itself lives in the git-ignored
Frameworks directory next to the binaries it describes. --self-test exercises
the classification and fail-closed behavior in a temporary tree.
"""
import argparse
import hashlib
import json
import sys
import tempfile
from pathlib import Path, PurePosixPath

MANIFEST_NAME = "dash-build-manifest.json"
GENERATOR = "floe-dash-provenance-v1"
FRAMEWORK_NAMES = ["dash", "dashA", "dashB", "dashC", "dashD", "dashE"]
SLICES = ["ios-arm64", "ios-arm64_x86_64-simulator"]
IGNORED_FILES = {".DS_Store"}
# Documentation never reaches the compiler or linker: man pages (dash.1 and
# bltin/*.1), upstream's TOUR, the license and the provenance notes. It is
# neither discovered as a build input nor allowed to fail a recorded check.
DOCUMENTATION_NAMES = {"COPYING", "PROVENANCE.md", "TOUR"}
DOCUMENTATION_SUFFIXES = (".md", ".1")
# Tracked configuration outside ThirdParty/DashIOS that does change the built
# frameworks: the build script owns the compiler/linker flags and the bundle
# assembly, and the FloeShellEngine manifest pins the ios_system artifact
# (URL + checksum) that build_dash_ios.sh links against.
BUILD_INPUT_FILES = (
    "scripts/build_dash_ios.sh",
    "ThirdParty/FloeShellEngine/Package.swift",
)


def is_documentation(relative: str) -> bool:
    name = PurePosixPath(relative).name
    return (name in DOCUMENTATION_NAMES
            or name.startswith("README")
            or name.endswith(DOCUMENTATION_SUFFIXES))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def combined_digest(files: dict) -> str:
    combined = hashlib.sha256()
    for relative in sorted(files):
        combined.update(relative.encode("utf-8"))
        combined.update(b"\0")
        combined.update(files[relative].encode("ascii"))
        combined.update(b"\0")
    return combined.hexdigest()


def build_inputs(source_dir: Path, repo_root: Path) -> dict:
    """Hash the DashIOS build inputs plus the tracked build configuration."""
    files = {}
    for path in sorted(source_dir.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(source_dir).as_posix()
        if path.name in IGNORED_FILES or is_documentation(relative):
            continue
        files[relative] = sha256_file(path)
    for relative in BUILD_INPUT_FILES:
        path = repo_root / relative
        if not path.is_file():
            raise FileNotFoundError(f"missing tracked build input: {path}")
        files[relative] = sha256_file(path)
    return {
        "files": files,
        "file_count": len(files),
        "source_sha256": combined_digest(files),
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


def build_manifest(source_dir: Path, frameworks_dir: Path, repo_root: Path) -> dict:
    return {
        "generator": GENERATOR,
        "source": build_inputs(source_dir, repo_root),
        "binaries": binary_inputs(frameworks_dir),
    }


def evaluate(manifest: dict, source_dir: Path, frameworks_dir: Path, repo_root: Path):
    """Return (problems, current_sources or None, current_binaries or None)."""
    problems = []
    current_sources = None
    current_binaries = None

    recorded_sources = manifest.get("source", {})
    # Documentation recorded by an older manifest is not a build input, so it
    # must not make the built binaries look stale.
    recorded_files = {
        relative: digest
        for relative, digest in recorded_sources.get("files", {}).items()
        if not is_documentation(relative)
    }
    try:
        current_sources = build_inputs(source_dir, repo_root)
    except FileNotFoundError as error:
        problems.append(f"{error}; the frameworks cannot be reproduced without it.")
    else:
        current_files = current_sources["files"]
        changed = sorted(relative for relative in current_files
                         if relative in recorded_files and recorded_files[relative] != current_files[relative])
        added = sorted(relative for relative in current_files if relative not in recorded_files)
        removed = sorted(relative for relative in recorded_files if relative not in current_files)
        if changed or added or removed:
            problems.append(
                "DashIOS build inputs changed after the frameworks were built "
                f"(changed={changed[:5]}{'…' if len(changed) > 5 else ''} "
                f"added={added[:5]}{'…' if len(added) > 5 else ''} "
                f"removed={removed[:5]}{'…' if len(removed) > 5 else ''}); "
                "re-run scripts/build_dash_ios.sh so the interactive-stdin and any other "
                "DashIOS source, build-script or linked-engine changes are actually compiled "
                "into the app inputs."
            )

    recorded_binaries = manifest.get("binaries", {})
    try:
        current_binaries = binary_inputs(frameworks_dir)
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
    return problems, current_sources, current_binaries


def self_test() -> int:
    """Exercise the input classification and the fail-closed checks."""
    failures = []

    def expect(condition: bool, label: str) -> None:
        print(f"{'ok  ' if condition else 'FAIL'}  {label}")
        if not condition:
            failures.append(label)

    with tempfile.TemporaryDirectory(prefix="floe-dash-provenance-self-test-") as temporary:
        repo = Path(temporary) / "repo"
        source_dir = repo / "ThirdParty" / "DashIOS"
        (source_dir / "src" / "bltin").mkdir(parents=True)
        (source_dir / "src" / "input.c").write_text("/* dash input */\n")
        (source_dir / "src" / "dash.1").write_text(".TH DASH 1\n")
        (source_dir / "src" / "bltin" / "test.1").write_text(".TH TEST 1\n")
        (source_dir / "configure.ac").write_text("AC_INIT([dash])\n")
        (source_dir / "Makefile.in").write_text("# generated\n")
        (source_dir / "basic_Info.plist").write_text("<plist/>\n")
        (source_dir / "PROVENANCE.md").write_text("docs\n")
        (source_dir / "COPYING").write_text("license\n")
        (repo / "scripts").mkdir()
        build_script = repo / "scripts" / "build_dash_ios.sh"
        build_script.write_text("#!/bin/bash\n")
        engine_dir = repo / "ThirdParty" / "FloeShellEngine"
        engine_dir.mkdir(parents=True)
        engine_pin = engine_dir / "Package.swift"
        engine_pin.write_text("// ios_system checksum pin\n")
        frameworks_dir = repo / "Frameworks"
        for name in FRAMEWORK_NAMES:
            for slice_name in SLICES:
                binary = frameworks_dir / f"{name}.xcframework" / slice_name / f"{name}.framework" / name
                binary.parent.mkdir(parents=True)
                binary.write_bytes(f"{name} {slice_name}\n".encode())

        manifest = build_manifest(source_dir, frameworks_dir, repo)
        files = manifest["source"]["files"]
        expect("src/input.c" in files, "compiled source is a build input")
        expect("configure.ac" in files and "basic_Info.plist" in files,
               "autotools configuration and plist templates are build inputs")
        expect("scripts/build_dash_ios.sh" in files, "build script is a build input")
        expect("ThirdParty/FloeShellEngine/Package.swift" in files,
               "linked-engine pin is a build input")
        expect(not any(is_documentation(relative) for relative in files),
               "documentation is not discovered as a build input")
        expect(evaluate(manifest, source_dir, frameworks_dir, repo)[0] == [],
               "recorded manifest passes check mode")

        # The reported failure: a docs-only edit must not invalidate a binary,
        # including when the recorded manifest lists that documentation.
        (source_dir / "PROVENANCE.md").write_text("docs changed\n")
        (source_dir / "src" / "dash.1").write_text(".TH DASH 1 changed\n")
        expect(evaluate(manifest, source_dir, frameworks_dir, repo)[0] == [],
               "documentation-only edits do not invalidate the binary")
        legacy = json.loads(json.dumps(manifest))
        legacy["source"]["files"]["PROVENANCE.md"] = sha256_file(source_dir / "PROVENANCE.md")
        expect(evaluate(legacy, source_dir, frameworks_dir, repo)[0] == [],
               "legacy manifest entries for documentation are ignored")
        legacy_gone = json.loads(json.dumps(manifest))
        legacy_gone["source"]["files"]["src/removed.c"] = "0" * 64
        expect(any("src/removed.c" in problem
                   for problem in evaluate(legacy_gone, source_dir, frameworks_dir, repo)[0]),
               "removed recorded build inputs still fail closed")

        (source_dir / "src" / "input.c").write_text("/* changed */\n")
        expect(any("src/input.c" in problem
                   for problem in evaluate(manifest, source_dir, frameworks_dir, repo)[0]),
               "compiled source drift fails closed")
        (source_dir / "src" / "input.c").write_text("/* dash input */\n")

        build_script.write_text("#!/bin/bash\nCFLAGS=-O0\n")
        expect(any("scripts/build_dash_ios.sh" in problem
                   for problem in evaluate(manifest, source_dir, frameworks_dir, repo)[0]),
               "build script drift fails closed")
        build_script.write_text("#!/bin/bash\n")

        engine_pin.write_text("// changed pin\n")
        expect(any("ThirdParty/FloeShellEngine/Package.swift" in problem
                   for problem in evaluate(manifest, source_dir, frameworks_dir, repo)[0]),
               "linked-engine pin drift fails closed")
        engine_pin.write_text("// ios_system checksum pin\n")

        binary = frameworks_dir / "dash.xcframework" / SLICES[0] / "dash.framework" / "dash"
        binary.write_bytes(b"changed binary\n")
        expect(any("binaries" in problem
                   for problem in evaluate(manifest, source_dir, frameworks_dir, repo)[0]),
               "binary drift fails closed")
        binary.write_bytes(f"dash {SLICES[0]}\n".encode())

        expect(evaluate(manifest, source_dir, frameworks_dir, repo)[0] == [],
               "restored inputs pass again")

    if failures:
        print(f"FAIL  dash provenance self-test: {len(failures)} check(s) failed", file=sys.stderr)
        return 1
    print("PASS  dash provenance self-test: classification and fail-closed behavior")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true",
                        help="record the manifest (used by build_dash_ios.sh)")
    parser.add_argument("--self-test", action="store_true",
                        help="exercise the input classification in a temporary tree")
    parser.add_argument("--source-dir", type=Path,
                        default=Path(__file__).resolve().parents[2] / "ThirdParty" / "DashIOS")
    parser.add_argument("--frameworks-dir", type=Path,
                        default=Path(__file__).resolve().parents[2] / "Frameworks")
    parser.add_argument("--repo-root", type=Path,
                        default=Path(__file__).resolve().parents[2],
                        help="FloeAgent root the build-script and engine-pin inputs resolve against")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    if not args.source_dir.is_dir():
        print(f"DashIOS source directory not found: {args.source_dir}", file=sys.stderr)
        return 2

    manifest_path = args.frameworks_dir / MANIFEST_NAME

    if args.write:
        manifest = build_manifest(args.source_dir, args.frameworks_dir, args.repo_root)
        args.frameworks_dir.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        print(f"wrote {manifest_path} ({manifest['source']['file_count']} build inputs, "
              f"{len(manifest['binaries'])} binaries, inputs {manifest['source']['source_sha256'][:16]}…)")
        return 0

    if not manifest_path.is_file():
        print(f"{manifest_path} is missing: build the dash frameworks with "
              f"scripts/build_dash_ios.sh (release tooling bootstrap) before checking provenance.",
              file=sys.stderr)
        return 1
    try:
        manifest = json.loads(manifest_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        print(f"{manifest_path} cannot be read: {error}", file=sys.stderr)
        return 1
    if manifest.get("generator") != GENERATOR:
        print(f"{manifest_path} has an unknown generator {manifest.get('generator')!r}; "
              f"rebuild the dash frameworks.", file=sys.stderr)
        return 1

    problems, current_sources, current_binaries = evaluate(
        manifest, args.source_dir, args.frameworks_dir, args.repo_root)
    if problems:
        for problem in problems:
            print(f"FAIL  {problem}", file=sys.stderr)
        return 1

    print(f"PASS  dash framework provenance: {current_sources['file_count']} build inputs "
          f"(sha256 {current_sources['source_sha256'][:16]}…) match "
          f"{len(current_binaries)} built binaries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
