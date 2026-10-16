#!/usr/bin/env python3
"""Rebuild the two ios_system frameworks that used statfs for non-disk-space work.

`shell.framework` (`find -fstype` -> statfs) and `text.framework` (`wc`'s
fstatfs I/O-size probe and `tail -F`'s fstatfs MNT_LOCAL probe) call
required-reason DiskSpace APIs whose data they do not use, so no approved
reason code describes them (Apple's DiskSpace reasons are 85F4.1 display,
E174.1 write-space check, 7D9E.1 opt-in bug report, B728.1 health research).
The shipping manifests therefore cannot declare DiskSpace truthfully.

This script rebuilds exactly those two frameworks from the pinned upstream
source commit with a reviewed patch that removes the three calls:
  * bsd_find/function.c: `-fstype` fails closed with an explicit message.
  * text_cmds/wc/wc.c: buffer sizing moves to `fstat().st_blksize`
    (fstat is a FileTimestamp API this binary already uses and declares).
  * text_cmds/tail/forward.c: follow mode uses the sleep fallback on every
    volume (correct on local and remote filesystems; -F still re-stats).

Every input and output is verified:
  * upstream commit, original file hashes, patch hash, patched file hashes;
  * exported symbol set must equal the shipped framework's set (ABI);
  * no statfs/fstatfs/statvfs/fstatvfs may remain in the rebuilt binary;
  * the FileTimestamp imports the manifests declare must remain;
  * arm64, iOS platform, deployment target matches the app.

The rebuilt bundles are written to --output together with PROVENANCE.json.
They are substituted into the archived app before signing (see
prepare_app_store_bundle.py --rebuilt-frameworks). The original pinned
SwiftPM artifacts are never modified and remain the rollback source.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

UPSTREAM_REPO = "https://github.com/holzschu/ios_system.git"
UPSTREAM_TAG = "v3.0.2"
UPSTREAM_COMMIT = "8d013c4aa0a88fc97c5e8b4c052a62e03c716fe9"
PATCH_NAME = "ios_system-v3.0.2-shell-text-privacy.patch"
PATCH_SHA256 = "66e5323956f6f1e1f58cbdac1c843f07452cf6c96aab7cf8fba86411552ae663"

# path -> (original sha256 at the pinned commit, patched sha256)
PATCHED_FILES = {
    "bsd_find/function.c": (
        "ce6dd47d394e5beb25081ed99f12ab23786bbbd19b4fdc219cf0e12fc1ba1584",
        "cdabc3763fa066275b7c4d9be024f6c5af987744df2c42b47477438e706ef1ff",
    ),
    "text_cmds/wc/wc.c": (
        "a3c7fc6874af6a42b32c888cfda8c014b9aec538a45e7438ad3708c68011dd40",
        "48dd701ccc67ba85364bcf5c0cb7b5cbb6d77543ede9f0613c081818710e269c",
    ),
    "text_cmds/tail/forward.c": (
        "4cabab36849f80e0bdc3c7c4ba3fcb9faa159090b3f2eb377bfcfdb8a2bb7810",
        "04f65b7d5448faf5cddf4a49d4f386a147614dfdd48d0902fbf4cd712d2dd4d8",
    ),
}

# Exported-symbol-set hashes of the shipped v3.0.2 frameworks these rebuilds
# must remain ABI-compatible with (sorted `nm -gU` name lists).
EXPECTED_EXPORT_SET_SHA256 = {
    "shell": "46ef9458bd446dafc4ce7a94f3202d7d81d7d74df45f40eaf5e1e33a077d4d77",
    "text": "0248456f6bbab49031bdf83295fcc30b4f44c58c473734147e821fa483c5e84a",
}

REQUIRED_REASON_DENYLIST = ("_statfs", "_fstatfs", "_statvfs", "_fstatvfs")
# FileTimestamp imports the controlled manifests declare for these bundles.
EXPECTED_FILE_TIMESTAMP_IMPORTS = {
    "shell": {"_stat", "_lstat"},
    "text": {"_stat", "_fstat", "_lstat"},
}

DEPLOYMENT_TARGET = "26.0"
OTHER_CFLAGS = "-Wno-error=incompatible-function-pointer-types"
FRAMEWORK_TARGETS = ("shell", "text")


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    return sha256_bytes(Path(path).read_bytes())


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, text=True,
                          capture_output=True, **kwargs)


def git(repo, *args):
    return run(["git", "-C", str(repo), *args]).stdout


def ensure_source(source_cache):
    """Clone the pinned upstream commit if it is not cached; verify it if it is."""
    source_cache = Path(source_cache).expanduser()
    if (source_cache / ".git").is_dir():
        head = git(source_cache, "rev-parse", "HEAD").strip()
        if head != UPSTREAM_COMMIT:
            raise SystemExit(f"cached source is at {head}, expected {UPSTREAM_COMMIT}; "
                             f"remove {source_cache} to re-fetch")
    else:
        if source_cache.exists():
            raise SystemExit(f"{source_cache} exists but is not a git checkout")
        source_cache.parent.mkdir(parents=True, exist_ok=True)
        print(f"cloning {UPSTREAM_REPO} {UPSTREAM_TAG} into {source_cache}")
        run(["git", "clone", "--depth", "1", "--branch", UPSTREAM_TAG,
             UPSTREAM_REPO, str(source_cache)])
        head = git(source_cache, "rev-parse", "HEAD").strip()
        if head != UPSTREAM_COMMIT:
            raise SystemExit(f"upstream tag moved: {UPSTREAM_TAG} is {head}, "
                             f"expected {UPSTREAM_COMMIT}")
    # The checkout must start from upstream bytes; a dirty tree is reviewed below.
    return source_cache


def file_state(source, relative):
    data = (source / relative).read_bytes()
    return sha256_bytes(data)


def prepare_source(source, patch_path):
    """Apply the reviewed patch if needed; verify both original and patched bytes."""
    states = {}
    for relative, (original, patched) in PATCHED_FILES.items():
        current = file_state(source, relative)
        if current == patched:
            states[relative] = "patched"
        elif current == original:
            states[relative] = "original"
        else:
            raise SystemExit(f"{relative} matches neither the pinned original nor "
                             f"the patched revision: {current}")
    if all(state == "patched" for state in states.values()):
        return "already-patched"
    if any(state == "patched" for state in states.values()):
        raise SystemExit(f"mixed patch state: {states}")
    run(["git", "-C", str(source), "apply", "--check", str(patch_path)])
    run(["git", "-C", str(source), "apply", str(patch_path)])
    for relative, (_, patched) in PATCHED_FILES.items():
        if file_state(source, relative) != patched:
            raise SystemExit(f"patch did not produce the reviewed revision for {relative}")
    return "patched"


def xcodebuild_version(env):
    return run(["xcrun", "xcodebuild", "-version"], env=env).stdout.strip()


def build(source, derived_data, env):
    commands = []
    for target in FRAMEWORK_TARGETS:
        argv = [
            "xcrun", "xcodebuild",
            "-project", str(source / "ios_system.xcodeproj"),
            "-scheme", target,
            "-configuration", "Release",
            "-sdk", "iphoneos",
            "-destination", "generic/platform=iOS",
            "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
            f"IPHONEOS_DEPLOYMENT_TARGET={DEPLOYMENT_TARGET}",
            "ONLY_ACTIVE_ARCH=NO", "ARCHS=arm64",
            f"OTHER_CFLAGS={OTHER_CFLAGS}",
            "-derivedDataPath", str(derived_data),
            "build",
        ]
        print("+ " + " ".join(argv))
        result = run(argv, env=env)
        if "BUILD SUCCEEDED" not in result.stdout:
            raise SystemExit(f"{target}: xcodebuild did not report success")
        commands.append(argv)
    return commands


def nm_names(binary, *flags):
    output = run(["nm", *flags, str(binary)]).stdout
    names = []
    for line in output.splitlines():
        parts = line.split()
        if parts:
            names.append(parts[-1])
    return names


def verify_binary(target, binary):
    archs = run(["lipo", "-archs", str(binary)]).stdout.split()
    if archs != ["arm64"]:
        raise SystemExit(f"{target}: expected a thin arm64 binary, got {archs}")
    exports = sorted(nm_names(binary, "-gU"))
    export_sha = sha256_bytes(("\n".join(exports) + "\n").encode())
    if export_sha != EXPECTED_EXPORT_SET_SHA256[target]:
        raise SystemExit(f"{target}: exported symbol set changed (ABI): {export_sha}")
    undefined = set(nm_names(binary, "-u"))
    remaining = sorted(undefined & set(REQUIRED_REASON_DENYLIST))
    if remaining:
        raise SystemExit(f"{target}: statfs-family imports remain: {remaining}")
    missing = sorted(EXPECTED_FILE_TIMESTAMP_IMPORTS[target] - undefined)
    if missing:
        raise SystemExit(f"{target}: expected FileTimestamp imports missing: {missing}")
    build = run(["xcrun", "vtool", "-show-build", str(binary)]).stdout
    if "platform IOS" not in build:
        raise SystemExit(f"{target}: not an iOS Mach-O\n{build}")
    versions = [line.split()[-1] for line in build.splitlines() if "minos" in line]
    if not versions or any(version != DEPLOYMENT_TARGET for version in versions):
        raise SystemExit(f"{target}: unexpected deployment target {versions}")
    return {"archs": archs, "exportSetSHA256": export_sha,
            "statfsImports": [],
            "fileTimestampImports": sorted(undefined & EXPECTED_FILE_TIMESTAMP_IMPORTS[target]),
            "binarySHA256": sha256_file(binary), "minos": DEPLOYMENT_TARGET}


def copy_minimal_bundle(products, output, target):
    source = products / f"{target}.framework"
    destination = output / f"{target}.framework"
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    shutil.copy2(source / target, destination / target)
    shutil.copy2(source / "Info.plist", destination / "Info.plist")
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source-cache", type=Path,
                        default=Path.home() / "Library/Caches/FloePrivacyRebuild/ios_system-v3.0.2")
    parser.add_argument("--output", type=Path, required=True,
                        help="directory that receives the rebuilt framework bundles")
    parser.add_argument("--derived-data", type=Path, default=None)
    args = parser.parse_args()

    import os
    env = dict(os.environ)
    if not env.get("DEVELOPER_DIR"):
        for candidate in ("/Applications/Xcode.app", "/Applications/Xcode-beta.app"):
            if Path(candidate, "Contents/Developer").is_dir():
                env["DEVELOPER_DIR"] = f"{candidate}/Contents/Developer"
                break
    if not shutil.which("xcrun", path=env.get("PATH")):
        raise SystemExit("xcrun is not available")

    patch_path = Path(__file__).resolve().parent / "patches" / PATCH_NAME
    if sha256_file(patch_path) != PATCH_SHA256:
        raise SystemExit("reviewed patch bytes changed; refusing to rebuild")

    source = ensure_source(args.source_cache)
    patch_state = prepare_source(source, patch_path)
    derived_data = args.derived_data or (Path(args.source_cache) / "DerivedData")
    derived_data.mkdir(parents=True, exist_ok=True)

    commands = build(source, derived_data, env)

    products = derived_data / "Build/Products/Release-iphoneos"
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    targets = {}
    for target in FRAMEWORK_TARGETS:
        bundle = copy_minimal_bundle(products, output, target)
        targets[target] = {
            "framework": bundle.name,
            "executable": target,
            "executableSHA256": sha256_file(bundle / target),
            "infoPlistSHA256": sha256_file(bundle / "Info.plist"),
        }
        targets[target].update(verify_binary(target, bundle / target))

    provenance = {
        "generator": "floe-ios_system-privacy-rebuild-v1",
        "upstream": {"repository": UPSTREAM_REPO, "tag": UPSTREAM_TAG,
                      "commit": UPSTREAM_COMMIT},
        "patch": {"name": PATCH_NAME, "sha256": PATCH_SHA256,
                   "patchedFileSHA256": {path: patched for path, (_, patched)
                                         in PATCHED_FILES.items()},
                   "originalFileSHA256": {path: original for path, (original, _)
                                          in PATCHED_FILES.items()},
                   "patchState": patch_state},
        "toolchain": xcodebuild_version(env),
        "build": {"deploymentTarget": DEPLOYMENT_TARGET, "archs": ["arm64"],
                   "otherCFlags": OTHER_CFLAGS,
                   "commands": [" ".join(command) for command in commands]},
        "policy": {
            "removedRequiredReasonAPIs": ["statfs (find -fstype)",
                                          "fstatfs (wc buffer sizing)",
                                          "fstatfs (tail follow-mode volume probe)"],
            "retainedRequiredReasonAPIs": ["stat/fstat/lstat (FileTimestamp)"],
            "unrelatedAPIsDeclaredInManifests": [],
        },
        "targets": targets,
        "rollback": "pinned FloeShellEngine v3.0.2 artifacts remain untouched; "
                    "delete this directory to fall back to them",
    }
    (output / "PROVENANCE.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(json.dumps(provenance, indent=2))
    print(f"rebuilt frameworks written to {output}")


if __name__ == "__main__":
    main()
