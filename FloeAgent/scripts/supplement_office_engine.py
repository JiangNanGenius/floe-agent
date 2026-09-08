#!/usr/bin/env python3
"""Reuse pinned iOS libraries and generate only missing embedding dependencies."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
from package_office_engine import digest, package

LOCK = Path(__file__).resolve().parent.parent / "ThirdParty/Collabora/engine.lock.json"
LIST = "source/engine/workdir/CustomTarget/ios/ios-all-static-libs.list"


def supplement(archive_path, root, lock_path=LOCK):
    root = Path(root).resolve()
    archive_path = Path(archive_path).resolve()
    lock = json.loads(Path(lock_path).read_text())
    if digest(archive_path) != lock["qualifiedNativeArtifact"]["archiveSHA256"]:
        raise ValueError("Downloaded native artifact does not match the locked archive")
    if root.exists():
        raise ValueError("Use a new build root; existing inputs must be preserved")
    root.mkdir(parents=True)
    logs = root / "qualification-logs"
    logs.mkdir()
    report = {"sourceCommit": lock["commit"], "stage": "start", "supplementPassed": False,
              "nativeCompilePassed": False, "deviceRoundtripPassed": False,
              "reusedRunID": lock["qualifiedNativeArtifact"]["runID"]}

    def save():
        (logs / "supplement.json").write_text(json.dumps(report, indent=2))

    def run(stage, command, cwd, env=None):
        report["stage"] = stage
        save()
        if shutil.disk_usage(root).free < lock["buildReserveGiB"] * 1024**3:
            raise RuntimeError("Embedding dependency work stopped at the disk reserve")
        print(stage, flush=True)
        with (logs / (stage + ".log")).open("w") as output:
            result = subprocess.run(command, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT)
        if result.returncode:
            report["failedStage"] = stage
            report["exitCode"] = result.returncode
            save()
            raise RuntimeError(f"{stage} failed; preserved {stage}.log")

    save()
    source = root / "source"
    run("source-init", ["git", "init", str(source)], root)
    run("source-remote", ["git", "remote", "add", "origin", lock["repository"]], source)
    run("source-fetch", ["git", "fetch", "--depth=1", "origin", lock["commit"]], source)
    run("source-checkout", ["git", "checkout", "--detach", "FETCH_HEAD"], source)
    with tarfile.open(archive_path) as archive:
        original = json.load(archive.extractfile("qualification.json"))
        if original["commit"] != lock["commit"] or not original["nativeBuildPassed"]:
            raise ValueError("Original engine qualification does not match source")
        if original["engineConfigureArguments"] != lock["engineConfigureArguments"] or original["sourcePatchSHA256"] != lock["sourcePatchSHA256"]:
            raise ValueError("Native configuration differs from the locked build")
        archive.extractall(root, filter="data")
    shutil.copy2(root / "qualification.json", logs / "original-qualification.json")
    patch = Path(lock_path).resolve().parent / lock["sourcePatch"]
    if digest(patch) != lock["sourcePatchSHA256"]:
        raise ValueError("Source patch does not match lock")
    run("source-patch", ["git", "apply", str(patch)], source)
    original_list = (root / LIST).read_text()
    (logs / "original-ios-linker.list").write_text(original_list)
    old_list = original["nativeArchiveManifest"]
    if not old_list.endswith(LIST):
        raise ValueError("Unexpected original linker manifest location")
    old_root = Path(old_list[:-len(LIST)])
    inputs = [Path(line).relative_to(old_root) for line in original_list.splitlines() if line.strip()]
    for name in inputs:
        if name.suffix not in {".a", ".o"} or ".." in name.parts:
            raise ValueError("Unsupported native linker input")
    archive_hashes = {str(name): digest(root / name) for name in inputs if name.suffix == ".a"}
    report["reusedArchives"] = len(archive_hashes)
    report["requiredLinkerObjects"] = sum(name.suffix == ".o" for name in inputs)
    save()
    engine = source / "engine"
    env = dict(os.environ, MAKE=shutil.which("gmake") or "gmake")
    run("engine-configure", ["perl", "./autogen.sh", *lock["engineConfigureArguments"]], engine, env)
    run("bootstrap-fetch", ["gmake", "-j2", "bootstrap", "fetch"], engine, env)
    # Pinned gbuild defines Executable_cppumaker via its user-friendly target
    # helper. gb_Side=build selects macOS host tools, not the iOS engine.
    run("header-generator", ["gmake", "-j2", "gb_Side=build", "-f", "Makefile.gbuild", "Executable_cppumaker"], engine, env)
    run("embedding-dependencies", ["gmake", "-j2", "-f", "Makefile.gbuild",
        "UnpackedTarball_boost", "UnpackedTarball_libpng", "UnpackedTarball_poco",
        "UnpackedTarball_zstd", "ExternalProject_nss"], engine, env)
    generator = engine / "workdir_for_build/LinkTarget/Executable/cppumaker"
    if not generator.is_file():
        raise ValueError("Pinned host cppumaker did not build at its expected path")
    # macOS gbuild delivers host libraries into the app-style Frameworks
    # directory, not the Unix/iOS program directory (confirmed in link logs).
    host_libraries = engine / "instdir_for_build/Contents/Frameworks"
    if not (host_libraries / "libunoidllo.dylib").is_file():
        raise ValueError("Host cppumaker libraries were not delivered")
    generator_env = dict(env, DYLD_LIBRARY_PATH=str(host_libraries))
    registries = engine / "workdir/CustomTarget/ios/resources"
    for api in ("udkapi", "offapi"):
        output = engine / "workdir/UnoApiHeadersTarget" / api / "comprehensive"
        output.mkdir(parents=True, exist_ok=True)
        command = [str(generator), "-Gc", "-C", "-O" + str(output), str(registries / (api + ".rdb"))]
        if api == "offapi":
            command.append("-X" + str(registries / "udkapi.rdb"))
        run("headers-" + api, command, engine, generator_env)
    # Targeted NSS regeneration may rebuild some libraries. Restore every
    # originally linked archive; retain only its newly generated missing .o's.
    with tarfile.open(archive_path) as archive:
        archive.extractall(root, members=[m for m in archive.getmembers() if m.name in archive_hashes], filter="data")
    for name, checksum in archive_hashes.items():
        if digest(root / name) != checksum:
            raise ValueError("A reused engine archive changed")
    for name in inputs:
        if not (root / name).is_file():
            raise ValueError(f"Missing linker input after supplementation: {name}")
    (root / LIST).write_text("\n".join(str(root / name) for name in inputs) + "\n")
    aliases = {"lobuilddir-symlink": "engine",
        "pocoinclude-symlink": "engine/workdir/UnpackedTarball/poco/include",
        "pocolib-symlink": "engine/workdir/LinkTarget/StaticLibrary",
        "zstdinclude-symlink": "engine/workdir/UnpackedTarball/zstd/lib",
        "zstdlib-symlink": "engine/workdir/LinkTarget/StaticLibrary"}
    for name, target in aliases.items():
        link = source / name
        if link.is_symlink():
            link.unlink()
        if link.exists():
            raise ValueError("Native alias collides with a real file")
        link.symlink_to(target)
    # These two upstream asset links contain source-root-relative targets.
    # Normalize only links whose recorded target resolves inside this source.
    report["normalizedAssetLinks"] = []
    for link in (source / "ios").rglob("*"):
        if link.is_symlink() and not link.exists():
            target = source / os.readlink(link)
            if target.is_file() and target.resolve().is_relative_to(source):
                link.unlink()
                link.symlink_to(os.path.relpath(target, link.parent))
                report["normalizedAssetLinks"].append(str(link.relative_to(source)))
    original["nativeArchiveManifest"] = str(root / LIST)
    original["reusedNativeRunID"] = report["reusedRunID"]
    original["embeddingInputsSupplemented"] = True
    original["embeddedEditorPassed"] = False
    original["deviceRoundtripPassed"] = False
    (root / "qualification.json").write_text(json.dumps(original, indent=2))
    manifest = package(root)
    report.update(supplementPassed=True, stage="packaged", filesPackaged=len(manifest["files"]),
                  linkerInputsPackaged=len(manifest["linkerInputs"]))
    save()
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("build_root", type=Path)
    args = parser.parse_args()
    print(json.dumps(supplement(args.archive, args.build_root), indent=2))
