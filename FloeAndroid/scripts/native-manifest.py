#!/usr/bin/env python3
"""Record exact native inputs and packaged library hashes.

Generation (explicit output directory, used by build-swift.sh):

    native-manifest.py PATH/TO/jniLibs/arm64-v8a

writes PATH/TO/jniLibs/native-manifest.json (the output directory's parent).

Read-only drift check (never writes anything):

    native-manifest.py PATH/TO/jniLibs/arm64-v8a --check [--manifest FILE]

The manifest records every Swift source that compiles into the shared core,
the Swift package manifest, JNI/CMake inputs, the native build/toolchain
scripts and toolchains.lock.json. A hash documents the exact bytes read when
the manifest was generated; it is not retroactive proof that an earlier binary
was built from those bytes. Regenerate after the final serialized build and
keep the source/APK provenance capture with the artifacts.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve()
DEFAULT_ROOT = SCRIPT.parents[2]  # repository root

# Exact files that define the native module and the toolchain used to build it.
BUILD_INPUTS = (
    "FloeAndroid/scripts/build-swift.sh",
    "FloeAndroid/scripts/env.sh",
    "FloeAndroid/scripts/configure-swift-sdk.py",
    "FloeAndroid/toolchains.lock.json",
    "FloeAndroid/core/swiftbridge/build.gradle.kts",
)

# These anchors must exist; their absence must not silently produce a smaller
# manifest that still looks valid.
REQUIRED_INPUTS = (
    "FloeAndroid/shared/Package.swift",
    "FloeAndroid/core/swiftbridge/src/main/cpp/floe_jni.cpp",
    "FloeAndroid/core/swiftbridge/src/main/cpp/CMakeLists.txt",
) + BUILD_INPUTS

NATIVE_SUFFIXES = (
    ".c",
    ".cc",
    ".cpp",
    ".cxx",
    ".h",
    ".hh",
    ".hpp",
    ".hxx",
    ".inl",
    ".cmake",
)


class ManifestError(Exception):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def repo_relative(root: Path, path: Path) -> str:
    return path.relative_to(root).as_posix()


def add_required_file(root: Path, relative: str, mapping: dict) -> None:
    path = root / relative
    if not path.is_file():
        raise ManifestError("required input missing: %s" % relative)
    mapping[relative] = sha256_file(path)


def collect_swift_inputs(root: Path, shared_sources: dict, source_links: dict) -> None:
    package = root / "FloeAndroid/shared/Package.swift"
    if not package.is_file():
        raise ManifestError("required input missing: %s" % repo_relative(root, package))
    add_required_file(root, repo_relative(root, package), shared_sources)

    sources_dir = root / "FloeAndroid/shared/Sources"
    if not sources_dir.is_dir():
        raise ManifestError("shared Swift sources directory missing: %s"
                            % repo_relative(root, sources_dir))
    swift_files = sorted(p for p in sources_dir.rglob("*.swift")
                         if p.is_file() or p.is_symlink())
    if not swift_files:
        raise ManifestError("no Swift sources found under %s"
                            % repo_relative(root, sources_dir))

    resolved_root = root.resolve()
    for path in swift_files:
        relative = repo_relative(root, path)
        if not path.is_file():
            raise ManifestError("Swift source is unreadable or a broken symlink: %s"
                                % relative)
        shared_sources[relative] = sha256_file(path)
        if not path.is_symlink():
            continue
        target = path.resolve()
        if not target.is_file():
            raise ManifestError("Swift source symlink target missing: %s -> %s"
                                % (relative, target))
        try:
            target_relative = target.relative_to(resolved_root).as_posix()
        except ValueError:
            raise ManifestError(
                "Swift source symlink resolves outside the repository: %s -> %s"
                % (relative, target)
            )
        source_links[relative] = target_relative
        # Record the actual source bytes too, so the manifest keeps working
        # when the original iOS path is inspected directly.
        shared_sources[target_relative] = sha256_file(target)


def collect_native_inputs(root: Path, native_inputs: dict) -> None:
    cpp_dir = root / "FloeAndroid/core/swiftbridge/src/main/cpp"
    if not cpp_dir.is_dir():
        raise ManifestError("JNI/CMake directory missing: %s"
                            % repo_relative(root, cpp_dir))

    candidates = set()
    for path in cpp_dir.rglob("*"):
        if path.name == "CMakeLists.txt" or path.suffix in NATIVE_SUFFIXES:
            if not path.is_file():
                raise ManifestError(
                    "native input is unreadable or a broken symlink: %s"
                    % repo_relative(root, path))
            candidates.add(path)
    if not candidates:
        raise ManifestError("no JNI/CMake inputs found under %s"
                            % repo_relative(root, cpp_dir))
    for path in sorted(candidates):
        relative = repo_relative(root, path)
        native_inputs[relative] = sha256_file(path)

    for relative in BUILD_INPUTS:
        add_required_file(root, relative, native_inputs)


def collect_libraries(output: Path) -> dict:
    if not output.is_dir():
        raise ManifestError("native output directory missing: %s" % output)
    libraries = {}
    for path in sorted(output.glob("*.so")):
        if not path.is_file():
            raise ManifestError("packaged library is unreadable or a broken symlink: %s"
                                % path.name)
        libraries[path.name] = sha256_file(path)
    if not libraries:
        raise ManifestError("no packaged .so libraries found in %s" % output)
    if "libFloeAndroidCore.so" not in libraries:
        raise ManifestError("libFloeAndroidCore.so missing from %s" % output)
    return libraries


def input_digest(shared_sources: dict, native_inputs: dict,
                 source_links: dict) -> str:
    payload = json.dumps(
        {
            "sharedSources": shared_sources,
            "nativeInputs": native_inputs,
            "sourceLinks": source_links,
        },
        sort_keys=True,
        ensure_ascii=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def require_anchors(root: Path) -> None:
    missing = [relative for relative in REQUIRED_INPUTS
               if not (root / relative).is_file()]
    if missing:
        raise ManifestError("required input(s) missing: %s" % ", ".join(missing))


def build_manifest(root: Path, output: Path) -> dict:
    require_anchors(root)
    lock_path = root / "FloeAndroid/toolchains.lock.json"
    if not lock_path.is_file():
        raise ManifestError("required input missing: %s"
                            % repo_relative(root, lock_path))
    try:
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ManifestError("toolchains.lock.json is unreadable: %s" % exc)
    for key in ("swift", "ndk"):
        if not lock.get(key):
            raise ManifestError("toolchains.lock.json lacks %s" % key)

    shared_sources = {}
    source_links = {}
    native_inputs = {}
    collect_swift_inputs(root, shared_sources, source_links)
    collect_native_inputs(root, native_inputs)
    libraries = collect_libraries(output)

    return {
        "schemaVersion": 1,
        "abi": "arm64-v8a",
        "swift": lock["swift"],
        "ndk": lock["ndk"],
        "inputDigest": input_digest(shared_sources, native_inputs, source_links),
        "sharedSources": shared_sources,
        "nativeInputs": native_inputs,
        "sourceLinks": source_links,
        "libraries": libraries,
    }


def diff_manifests(recorded, computed, prefix=""):
    """Return human-readable differences between two manifest structures."""
    lines = []
    if type(recorded) is not type(computed):
        lines.append("%s: recorded type %s, computed type %s"
                     % (prefix or "<root>", type(recorded).__name__,
                        type(computed).__name__))
        return lines
    if isinstance(recorded, dict):
        for key in sorted(set(recorded) | set(computed)):
            label = "%s.%s" % (prefix, key) if prefix else str(key)
            if key not in computed:
                lines.append("%s: recorded but not computed" % label)
            elif key not in recorded:
                lines.append("%s: computed but not recorded" % label)
            else:
                lines.extend(diff_manifests(recorded[key], computed[key], label))
        return lines
    if recorded != computed:
        lines.append("%s: recorded %r, computed %r"
                     % (prefix or "<root>", recorded, computed))
    return lines


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Record or read-only check the Android native input manifest"
    )
    parser.add_argument("output", type=Path,
                        help="directory containing the packaged .so libraries")
    parser.add_argument("--check", action="store_true",
                        help="compare with the recorded manifest; never write")
    parser.add_argument("--manifest", type=Path,
                        help="manifest to compare against with --check "
                             "(default: OUTPUT/../native-manifest.json)")
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT,
                        help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    if args.manifest is not None and not args.check:
        parser.error("--manifest is only valid with --check")

    root = args.root.resolve()
    output = args.output.resolve()
    try:
        computed = build_manifest(root, output)
    except (ManifestError, OSError) as exc:
        print("native-manifest: FAIL %s" % exc, file=sys.stderr)
        return 1

    if args.check:
        target = args.manifest if args.manifest is not None else \
            output.parent / "native-manifest.json"
        if not target.is_file():
            print("native-manifest: FAIL recorded manifest missing: %s"
                  % target, file=sys.stderr)
            return 1
        try:
            recorded = json.loads(target.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            print("native-manifest: FAIL recorded manifest is unreadable: %s"
                  % exc, file=sys.stderr)
            return 1
        drift = diff_manifests(recorded, computed)
        if drift:
            for line in drift:
                print("DRIFT %s" % line)
            print("native-manifest: drift detected; recorded manifest was not "
                  "rewritten (%s)" % target)
            return 1
        print("native-manifest: OK %d libraries, %d shared sources, %d native "
              "inputs match %s"
              % (len(computed["libraries"]), len(computed["sharedSources"]),
                 len(computed["nativeInputs"]), target))
        return 0

    target = output.parent / "native-manifest.json"
    target.write_text(json.dumps(computed, indent=2) + "\n", encoding="utf-8")
    print("Native manifest: %d libraries, %d shared sources, %d native inputs "
          "-> %s" % (len(computed["libraries"]),
                     len(computed["sharedSources"]),
                     len(computed["nativeInputs"]), target))
    return 0


if __name__ == "__main__":
    sys.exit(main())
