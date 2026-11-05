#!/usr/bin/env python3
"""Bind one signed optional Office split to its exact signed base APK.

Run after the serialized producer build. Base release qualification remains in
prepare-stage-release.py; this verifies the relocated Office payload itself,
including every prepared asset and the unchanged pinned ARM64 libraries.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import sys
import zipfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("floe_stage_release", HERE / "prepare-stage-release.py")
stage = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = stage
spec.loader.exec_module(stage)


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--base-apk", type=Path, required=True)
    parser.add_argument("--prepared-assets", type=Path, required=True)
    parser.add_argument("--apksigner", type=Path, required=True)
    parser.add_argument("--aapt2", type=Path, required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--release-assets", type=Path,
        help="existing prepared base release assets; add only the verified component and its checksum")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.source):
        parser.error("--source must be the exact immutable producer commit")
    pins = json.loads((HERE.parent / "core/officeengine/payload-pins.json").read_text())
    base = stage.badging_facts(args.aapt2, args.base_apk)
    split = stage.badging_facts(args.aapt2, args.apk)
    for key in ("package", "versionCode", "versionName"):
        if base[key] != split[key]:
            raise ValueError("base/component identity mismatch: " + key)
    text = stage.run_readonly_tool([str(args.aapt2), "dump", "badging", str(args.apk)])
    if text.returncode != 0 or not re.search(r"\bsplit='officepreview'", text.stdout):
        raise ValueError("the APK is not the declared Office feature split")
    base_signing = stage.signing_facts(args.apksigner, args.base_apk)
    split_signing = stage.signing_facts(args.apksigner, args.apk)
    if not base_signing["verified"] or not split_signing["verified"]:
        raise ValueError("both artifacts require verified non-debug modern signatures")
    if base_signing["certSha256"] != split_signing["certSha256"]:
        raise ValueError("base/component signer mismatch")
    native = {}
    with zipfile.ZipFile(args.base_apk) as base_zip, zipfile.ZipFile(args.apk) as archive:
        base_names = set(base_zip.namelist())
        if any("lib/arm64-v8a/" + name in base_names for name in pins["libraries"]):
            raise ValueError("Office payload remains embedded in the base APK")
        infos = archive.infolist()
        if len(infos) != len({entry.filename for entry in infos}):
            raise ValueError("duplicate ZIP entries")
        libraries = [entry for entry in infos if entry.filename.startswith("lib/") and not entry.is_dir()]
        if {entry.filename for entry in libraries} != {"lib/arm64-v8a/" + name for name in pins["libraries"]}:
            raise ValueError("component native library set does not match the exact payload pins")
        available = {Path(name).name for name in base_names if name.startswith("lib/arm64-v8a/")}
        available.update(pins["libraries"])
        available.update(stage.ANDROID_PUBLIC_LIBRARIES)
        for entry in libraries:
            data = archive.read(entry)
            if hashlib.sha256(data).hexdigest() != pins["libraries"][Path(entry.filename).name]:
                raise ValueError("Office library pin drift: " + entry.filename)
            facts = stage.elf_facts(data)
            if facts["machine"] != 183 or facts["minLoadAlignment"] < stage.PAGE_16K:
                raise ValueError("invalid ARM64/16KiB library: " + entry.filename)
            if any(value not in available or "/" in value for value in facts["needed"]):
                raise ValueError("unresolved dependency: " + entry.filename)
            if entry.compress_type == zipfile.ZIP_STORED and stage.zip_data_offset(archive, entry) % stage.PAGE_16K:
                raise ValueError("stored native entry is not 16KiB ZIP-aligned")
            native[entry.filename] = {"sha256": hashlib.sha256(data).hexdigest(),
                "bytes": len(data), "minLoadAlignment": facts["minLoadAlignment"]}
        source = args.prepared_assets.resolve(strict=True)
        expected = {}
        for file in source.rglob("*"):
            if file.is_symlink():
                raise ValueError("prepared asset tree contains a symlink")
            if file.is_file():
                expected["assets/" + file.relative_to(source).as_posix()] = sha(file)
        actual = {entry.filename for entry in infos if entry.filename.startswith("assets/") and not entry.is_dir()}
        if not expected or actual != set(expected):
            raise ValueError("component assets differ from the verified prepared payload")
        for name, digest in expected.items():
            if hashlib.sha256(archive.read(name)).hexdigest() != digest:
                raise ValueError("prepared asset mismatch: " + name)
    version = base["versionName"]
    if not re.fullmatch(r"[A-Za-z0-9.+-]{1,96}", version):
        raise ValueError("unsafe version name")
    args.output.mkdir(parents=True, exist_ok=True)
    name = "Floe-Office-Preview-{}-full-arm64-v8a.component".format(version)
    target = args.output / name
    if target.exists() and sha(target) != sha(args.apk):
        raise ValueError("refusing to replace a different frozen component")
    if not target.exists():
        temporary = args.output / (name + ".part")
        shutil.copyfile(args.apk, temporary)
        temporary.replace(target)
    record = {"schema": "floe-office-component/1", "module": "officepreview",
        "sourceCommit": args.source, "packageName": base["package"],
        "versionCode": base["versionCode"], "versionName": version,
        "baseApkSha256": sha(args.base_apk), "sha256": sha(target), "bytes": target.stat().st_size,
        "signerSha256": split_signing["certSha256"], "nativeLibraries": native,
        "preparedAssetCount": len(expected), "payloadSourceRevision": pins["source"]["revision"]}
    (args.output / "OFFICE_COMPONENT_SAVED.json").write_text(json.dumps(record, indent=2) + "\n")
    # Add this exact line to the main release SHA256SUMS; keep the provenance
    # record private with the saved producer artifacts.
    (args.output / "OFFICE_COMPONENT.sha256").write_text(sha(target) + "  " + name + "\n")
    if args.release_assets is not None:
        directory = args.release_assets.resolve(strict=True)
        if not directory.is_dir() or directory == args.output.resolve():
            raise ValueError("public assets must be a separate existing directory")
        checksum = directory / "SHA256SUMS"
        text = checksum.read_text(encoding="ascii")
        entries = {}
        for line in text.splitlines():
            fields = line.split("  ", 1)
            if len(fields) != 2 or not re.fullmatch(r"[0-9a-f]{64}", fields[0]):
                raise ValueError("invalid prepared release checksum")
            if fields[1] in entries or Path(fields[1]).name != fields[1]:
                raise ValueError("unsafe/duplicate release checksum entry")
            entries[fields[1]] = fields[0]
        # Accept the producer's exact canonical base name, not a guessed APK.
        base_candidates = [key for key, digest in entries.items()
            if key.endswith(".apk") and digest == record["baseApkSha256"]]
        if len(base_candidates) != 1 or sha(directory / base_candidates[0]) != record["baseApkSha256"]:
            raise ValueError("prepared assets are not bound to this base APK")
        if name in entries and entries[name] != record["sha256"]:
            raise ValueError("refusing to change a published component digest")
        public = directory / name
        if public.exists() and (public.is_symlink() or sha(public) != record["sha256"]):
            raise ValueError("refusing to replace a different public component")
        if not public.exists():
            with public.open("xb") as stream, target.open("rb") as source_stream:
                shutil.copyfileobj(source_stream, stream)
                stream.flush(); os.fsync(stream.fileno())
        if sha(public) != record["sha256"]:
            raise ValueError("public component read-back mismatch")
        if name not in entries:
            temporary = directory / ".office-checksums.part"
            with temporary.open("xb") as stream:
                stream.write((text.rstrip("\n") + "\n" + record["sha256"] + "  " + name + "\n").encode("ascii"))
                stream.flush(); os.fsync(stream.fileno())
            temporary.replace(checksum)
    print(json.dumps({"asset": name, "sha256": sha(target), "bytes": target.stat().st_size}))


if __name__ == "__main__":
    main()
