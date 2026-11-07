#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Bind one signed optional CAD viewer split to its exact signed base APK.

Run after the serialized producer build (``:cadpreview:assembleFullRelease``).
The CAD payload is asset-only (hasCode=false): this verifies the relocated
viewer bytes against the base APK's own hash-pinned manifest
(``assets/preview_components/cad.json``), proves base/component identity and
one signer, and refuses Android DEX/native code. Base release qualification
remains in prepare-stage-release.py.
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
spec = importlib.util.spec_from_file_location(
    "floe_stage_release", HERE / "prepare-stage-release.py")
stage = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = stage
spec.loader.exec_module(stage)

PIN_MANIFEST = "assets/preview_components/cad.json"
CAD_ROOT = "assets/cad_viewer"
SCHEMA = "floe-cad-component/1"
MODULE = "cadpreview"


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", type=Path, required=True,
        help="built :cadpreview full release split APK")
    parser.add_argument("--base-apk", type=Path, required=True)
    parser.add_argument("--apksigner", type=Path, required=True)
    parser.add_argument("--aapt2", type=Path, required=True)
    parser.add_argument("--source", required=True,
        help="exact immutable producer commit (40 hex)")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--release-assets", type=Path,
        help="existing prepared base release assets; add only the verified component and its checksum")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.source):
        parser.error("--source must be the exact immutable producer commit")

    base = stage.badging_facts(args.aapt2, args.base_apk)
    split = stage.badging_facts(args.aapt2, args.apk)
    for key in ("package", "versionCode", "versionName"):
        if base[key] != split[key]:
            raise ValueError("base/component identity mismatch: " + key)
    text = stage.run_readonly_tool(
        [str(args.aapt2), "dump", "badging", str(args.apk)])
    if text.returncode != 0 or not re.search(r"\bsplit='" + MODULE + r"'", text.stdout):
        raise ValueError("the APK is not the declared CAD feature split")
    base_signing = stage.signing_facts(args.apksigner, args.base_apk)
    split_signing = stage.signing_facts(args.apksigner, args.apk)
    for proof in (base_signing, split_signing):
        if (not proof["verified"] or not proof["modernScheme"] or
                proof["debugCertificate"] or proof["signerCount"] != 1):
            raise ValueError("both artifacts require one verified non-debug modern signer")
    if base_signing["certSha256"] != split_signing["certSha256"]:
        raise ValueError("base/component signer mismatch")

    # The pin manifest is read from the shipped base APK so the component is
    # bound to what users actually install, not to a moving source tree.
    with zipfile.ZipFile(args.base_apk) as base_zip:
        manifest_bytes = base_zip.read(PIN_MANIFEST)
    manifest = json.loads(manifest_bytes.decode("utf-8"))
    if manifest.get("schemaVersion") != 1 or manifest.get("id") != "cad-v1":
        raise ValueError("unexpected CAD pin manifest identity")
    if not re.fullmatch(r"[0-9a-f]{40}", manifest.get("sourceCommit", "")):
        raise ValueError("CAD pin manifest source commit invalid")
    expected = {}
    for entry in manifest["files"]:
        name = entry["name"]
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", name):
            raise ValueError("unsafe pinned file name: " + name)
        if entry["bytes"] < 0 or entry["bytes"] > 64 * 1024 * 1024:
            raise ValueError("pinned file size invalid: " + name)
        if not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]):
            raise ValueError("pinned file digest invalid: " + name)
        expected[CAD_ROOT + "/" + name] = (entry["sha256"], entry["bytes"])

    assets = {}
    with zipfile.ZipFile(args.apk) as archive:
        infos = archive.infolist()
        if len(infos) != len({entry.filename for entry in infos}):
            raise ValueError("duplicate ZIP entries")
        names = [entry.filename for entry in infos]
        if any(name.startswith("lib/") for name in names):
            raise ValueError("CAD component must not carry native libraries")
        if any(re.fullmatch(r"classes\d*\.dex", name) for name in names):
            raise ValueError("CAD component is asset-only (hasCode=false): DEX refused")
        actual = {name for name in names
            if name.startswith("assets/") and not name.endswith("/")}
        if actual != set(expected):
            raise ValueError("component assets differ from the base-pinned manifest")
        for name in actual:
            data = archive.read(name)
            digest, size = expected[name]
            if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
                raise ValueError("pinned asset mismatch: " + name)
            assets[name] = {"sha256": digest, "bytes": size}

    version = base["versionName"]
    if not re.fullmatch(r"[A-Za-z0-9.+-]{1,96}", version):
        raise ValueError("unsafe version name")
    args.output.mkdir(parents=True, exist_ok=True)
    name = "Floe-CAD-Preview-{}-full-arm64-v8a.component".format(version)
    target = args.output / name
    if target.exists() and sha(target) != sha(args.apk):
        raise ValueError("refusing to replace a different frozen component")
    if not target.exists():
        temporary = args.output / (name + ".part")
        shutil.copyfile(args.apk, temporary)
        temporary.replace(target)
    record = {
        "schema": SCHEMA,
        "module": MODULE,
        "sourceCommit": args.source,
        "packageName": base["package"],
        "versionCode": base["versionCode"],
        "versionName": version,
        "baseApkSha256": sha(args.base_apk),
        "pinManifestSha256": hashlib.sha256(manifest_bytes).hexdigest(),
        "sha256": sha(target),
        "bytes": target.stat().st_size,
        "signerSha256": split_signing["certSha256"],
        "assetCount": len(assets),
        "assets": assets,
    }
    (args.output / "CAD_COMPONENT_SAVED.json").write_text(
        json.dumps(record, indent=2, sort_keys=True) + "\n")
    # Add this exact line to the main release SHA256SUMS; keep the provenance
    # record private with the saved producer artifacts.
    (args.output / "CAD_COMPONENT.sha256").write_text(
        sha(target) + "  " + name + "\n")
    if args.release_assets is not None:
        directory = args.release_assets.resolve(strict=True)
        if not directory.is_dir() or directory == args.output.resolve():
            raise ValueError("public assets must be a separate existing directory")
        checksum = directory / "SHA256SUMS"
        body = checksum.read_text(encoding="ascii")
        entries = {}
        for line in body.splitlines():
            fields = line.split("  ", 1)
            if len(fields) != 2 or not re.fullmatch(r"[0-9a-f]{64}", fields[0]):
                raise ValueError("invalid prepared release checksum")
            if fields[1] in entries or Path(fields[1]).name != fields[1]:
                raise ValueError("unsafe/duplicate release checksum entry")
            entries[fields[1]] = fields[0]
        base_candidates = [key for key, digest in entries.items()
            if key.endswith(".apk") and digest == record["baseApkSha256"]]
        if len(base_candidates) != 1 or \
                sha(directory / base_candidates[0]) != record["baseApkSha256"]:
            raise ValueError("prepared assets are not bound to this base APK")
        if name in entries and entries[name] != record["sha256"]:
            raise ValueError("refusing to change a published component digest")
        public = directory / name
        if public.exists() and (public.is_symlink() or sha(public) != record["sha256"]):
            raise ValueError("refusing to replace a different public component")
        if not public.exists():
            with public.open("xb") as stream, target.open("rb") as source_stream:
                shutil.copyfileobj(source_stream, stream)
                stream.flush()
                os.fsync(stream.fileno())
        if sha(public) != record["sha256"]:
            raise ValueError("public component read-back mismatch")
        if name not in entries:
            temporary = directory / ".cad-checksums.part"
            with temporary.open("xb") as stream:
                stream.write((body.rstrip("\n") + "\n" +
                    record["sha256"] + "  " + name + "\n").encode("ascii"))
                stream.flush()
                os.fsync(stream.fileno())
            temporary.replace(checksum)
    print(json.dumps({"asset": name, "sha256": sha(target),
        "bytes": target.stat().st_size, "assets": len(assets)}))


if __name__ == "__main__":
    main()
