#!/usr/bin/env python3
"""Compile/link the pinned Mobile UI in isolation; never certify Floe integration."""
import argparse
import copy
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

from package_office_engine import digest
from prepare_office_native_sources import prepare, DEFAULT_LOCK


def qualification_project(project, linker_list, minimum_ios, frameworks):
    """Keep upstream editor sources/resources, omit its release-only machinery."""
    project = copy.deepcopy(project)
    objects = project["objects"]
    targets = [obj for obj in objects.values()
               if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "Mobile"]
    if len(targets) != 1:
        raise ValueError("Expected exactly one pinned Mobile target")
    target = targets[0]
    target["dependencies"] = []  # Floe does not embed the upstream QuickLook extension.
    target["buildPhases"] = [key for key in target["buildPhases"]
        if objects[key]["isa"] not in {"PBXShellScriptBuildPhase", "PBXCopyFilesBuildPhase"}]
    for obj in objects.values():
        if obj.get("isa") == "XCBuildConfiguration":
            settings = obj["buildSettings"]
            settings["IPHONEOS_DEPLOYMENT_TARGET"] = minimum_ios
            settings["CODE_SIGNING_ALLOWED"] = "NO"
            # This is a local qualification app, never a release product.
            settings["DEBUG_INFORMATION_FORMAT"] = "dwarf"
            if "OTHER_LDFLAGS" in settings:
                flags = settings["OTHER_LDFLAGS"]
                if not isinstance(flags, list) or flags.count("-filelist") != 1:
                    raise ValueError("Pinned Mobile linker settings changed")
                flags[flags.index("-filelist") + 1] = str(linker_list)
                for framework in frameworks:
                    flags.extend(["-framework", framework])
    # Upstream copies test/data then removes it in its Release script. It is
    # unrelated to editor resources and need not enter this qualification app.
    for key in target["buildPhases"]:
        phase = objects[key]
        if phase["isa"] == "PBXResourcesBuildPhase":
            phase["files"] = [entry for entry in phase["files"]
                if objects[objects[entry]["fileRef"]].get("path") != "../test/data"]
    return project


def qualify(root, destination, *, build=True, lock_path=DEFAULT_LOCK):
    root, destination = Path(root).resolve(), Path(destination).resolve()
    if destination.exists():
        raise ValueError("Use a new output directory; previous build evidence is preserved")
    lock = json.loads(Path(lock_path).read_text())
    destination.mkdir(parents=True)
    report = {"sourceCommit": lock["commit"], "overlaySHA256": lock["embeddingOverlay"]["sha256"],
              "nativeCompilePassed": False, "nativeLinkPassed": False,
              "embeddedEditorPassed": False, "deviceRoundtripPassed": False,
              "stage": "verify-inputs"}

    def save():
        (destination / "qualification.json").write_text(json.dumps(report, indent=2) + "\n")

    save()
    try:
        overlay = prepare(root, lock_path)
    except Exception as error:
        report.update(stage="input-verification-failed", error=str(error))
        save()
        raise
    report["stage"] = "prepare"
    save()
    source = root / "source"
    shadow = destination / "source"
    shadow.mkdir()
    # Only ios/kit need changed files. All large engine inputs stay read-only
    # in the verified bundle; no hard links or source-tree build outputs.
    for child in source.iterdir():
        target = shadow / child.name
        if child.name in {"ios", "kit"}:
            shutil.copytree(child, target, symlinks=True)
            for link in target.rglob("*"):
                if link.is_symlink():
                    original = source / link.relative_to(shadow)
                    resolved = original.resolve(strict=True)
                    if not resolved.is_relative_to(root):
                        raise ValueError("Source alias escapes verified inputs")
                    link.unlink()
                    link.symlink_to(resolved)
        else:
            target.symlink_to(child.resolve(strict=True))
    for name, checksum in overlay["files"].items():
        path = shadow / name
        if path.is_symlink():
            path.unlink()
        shutil.copyfile(root / "prepared/native" / name, path)
        if digest(path) != checksum:
            raise ValueError("Qualification does not compile the prepared overlay")
    # configure normally creates this root alias; the old qualified archive
    # retained the ICU data but omitted the alias. Use its one actual data file.
    icu = shadow / "ICU.dat"
    if not icu.exists():
        candidates = list((source / "engine/workdir/CustomTarget/ios/resources").glob("icudt*l.dat"))
        if len(candidates) != 1:
            raise ValueError("Cannot identify one qualified ICU resource")
        icu.symlink_to(candidates[0])
    # Optional user-imported fonts folder is empty in the pinned source. Engine
    # fonts remain in the unchanged share/fonts resources, not this directory.
    (shadow / "ios/Mobile/Fonts").mkdir(exist_ok=True)
    project_path = shadow / "ios/Mobile.xcodeproj/project.pbxproj"
    project = plistlib.loads(subprocess.check_output(["plutil", "-convert", "xml1", "-o", "-", str(project_path)]))
    project = qualification_project(project, root / "prepared/ios-all-static-libs.list",
                                    lock["minimumIOS"], overlay["requiredFrameworks"])
    project_path.write_bytes(plistlib.dumps(project))
    report["projectSHA256"] = digest(project_path)
    command = ["xcodebuild", "-project", str(project_path.parent), "-target", "Mobile",
        "-configuration", "Release", "-sdk", "iphoneos", "-jobs", "2",
        "-resultBundlePath", str(destination / "Mobile.xcresult"),
        "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "CODE_SIGNING_ALLOWED=NO",
        "COMPILER_INDEX_STORE_ENABLE=NO", "LOSRCDIR=" + str(source / "engine"),
        "SYMROOT=" + str(destination / "products"), "OBJROOT=" + str(destination / "objects"), "build"]
    report.update(stage="prepared", command=command)
    save()
    if not build:
        return report
    if shutil.disk_usage(destination).free < lock["buildReserveGiB"] * 1024**3:
        raise RuntimeError("Native UI qualification stopped at the disk reserve")
    report["stage"] = "build"
    save()
    with (destination / "xcodebuild.log").open("w") as output:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT)
    report["exitCode"] = result.returncode
    executable = destination / "products/Release-iphoneos/Mobile.app/Mobile"
    report["nativeCompilePassed"] = result.returncode == 0 and executable.is_file()
    report["nativeLinkPassed"] = report["nativeCompilePassed"]
    report["stage"] = "built" if report["nativeLinkPassed"] else "failed"
    if executable.is_file():
        report["executableSHA256"] = digest(executable)
        report["platformLoadCommands"] = subprocess.check_output(
            ["xcrun", "vtool", "-show-build", str(executable)], text=True)
    save()
    if not report["nativeLinkPassed"]:
        raise RuntimeError("Native Mobile qualification failed; inspect preserved xcodebuild.log")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    print(json.dumps(qualify(args.bundle, args.output, build=not args.prepare_only), indent=2))
