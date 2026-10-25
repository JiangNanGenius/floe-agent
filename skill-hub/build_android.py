#!/usr/bin/env python3
"""Build the Android guide channel without rewriting the legacy iOS feed.

The reviewed guides.json authors Android manifest variants of guidance-only
sources. Scripted packages require a separately authored/qualified package;
this generator never infers binary or script compatibility from an OS name.
Catalog signatures authenticate ZIP hashes; ZIPs are not separately signed.
"""
import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import zipfile

import build

ROOT = Path(__file__).resolve().parent
CHANNEL = "skill-hub/android"


def candidates():
    policy = json.loads((ROOT / "android/guides.json").read_bytes())
    if (policy.get("schemaVersion") != 1 or policy.get("platform") != "android"
            or set(policy.get("guides", {})) != set(build.IDS)):
        raise ValueError("Android guide policy must explicitly author the four official IDs")
    build.validate_version(policy.get("minimumAppVersion"), "minimumAppVersion")
    outputs, packages = {}, []
    for identifier in build.IDS:
        authored = policy["guides"][identifier]
        if authored.get("source") != identifier:
            raise ValueError("Android guide source identity changed")
        version = build.validate_version(authored.get("version"))
        folder = ROOT / "sources" / identifier
        if folder.is_symlink() or not folder.is_dir():
            raise ValueError("Android guide source must be a plain directory")
        files = {}
        for path in sorted(folder.rglob("*")):
            if path.is_symlink():
                raise ValueError("symlink in Android guide source")
            if path.is_file() and path.name != "release.json":
                relative = path.relative_to(folder).as_posix()
                if relative.split("/")[0].casefold() == "scripts":
                    raise ValueError("Scripted guides need a separately qualified Android source")
                files[relative] = path.read_bytes()
        if (len(files) > 128 or any(len(data) > 2_097_152 for data in files.values())
                or sum(map(len, files.values())) > 262_144):
            raise ValueError("oversized Android guidance package")
        manifest = json.loads(files["floe.json"])
        release = json.loads((folder / "release.json").read_bytes())
        build.validate_release(release)
        build.validate_guide_metadata(files["SKILL.md"].decode(), manifest, release)
        if (manifest.get("id") != identifier or manifest.get("scriptRuntime") != "none"
                or manifest.get("pythonPackages", []) or manifest.get("runtime") is not None):
            raise ValueError("Only explicitly script-free guidance may share Android source text")
        # This is an authored variant in a DIFFERENT immutable namespace, never
        # a rewrite of a published iOS manifest. Generic Linux remains accepted
        # by older Android runtime bindings; iOS does not match either value.
        manifest = dict(manifest, version=version, platforms=["android", "linux"])
        files["floe.json"] = build.encoded(manifest)
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_STORED) as archive:
            for name, data in sorted(files.items()):
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = 0o100644 << 16
                archive.writestr(info, data)
        data = buffer.getvalue()
        relative = f"android/packages/{identifier}/{version}/{identifier}.zip"
        path = ROOT / relative
        if path.is_symlink():
            raise ValueError("Android archive must not be a symlink")
        if path.exists() and path.read_bytes() != data:
            raise ValueError(f"immutable Android version changed: {relative}; bump guides.json version")
        outputs[path] = data
        packages.append(dict(
            id=identifier, version=version, path="skill-hub/" + relative,
            size=len(data), sha256=hashlib.sha256(data).hexdigest(),
            contentDigest=build.canonical(files),
            minimumAppVersion=policy["minimumAppVersion"],
            releaseNotes=release["releaseNotes"], platforms=["android"],
            guideOnly=True, executionVerified=False))
    catalog = build.encoded(dict(schemaVersion=3, publisher="JiangNanGenius",
                                 platform="android", packages=packages))
    outputs[ROOT / "android/catalog.json"] = catalog
    return outputs, packages, catalog


def verify_released():
    """Read and verify the actual released Android bytes, never repair them."""
    catalog_path, signature_path = ROOT / "android/catalog.json", ROOT / "android/catalog.sig"
    if not catalog_path.exists() and not signature_path.exists():
        return None
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    public = json.loads((ROOT / "public-key.json").read_bytes())
    signature = json.loads(signature_path.read_bytes())
    if signature.get("keyID") != public["keyID"]:
        raise ValueError("unknown Android catalog signing key")
    raw = catalog_path.read_bytes()
    Ed25519PublicKey.from_public_bytes(base64.b64decode(public["publicKey"], validate=True)).verify(
        base64.b64decode(signature["signature"], validate=True), raw)
    catalog = json.loads(raw)
    entries = catalog.get("packages", [])
    if (catalog.get("schemaVersion") != 3 or catalog.get("platform") != "android"
            or catalog.get("publisher") != "JiangNanGenius"
            or len(entries) != len(build.IDS)
            or {entry["id"] for entry in entries} != set(build.IDS)):
        raise ValueError("invalid Android catalog identity")
    for entry in entries:
        identifier, version = entry["id"], build.validate_version(entry["version"])
        if entry["path"] != f"{CHANNEL}/packages/{identifier}/{version}/{identifier}.zip":
            raise ValueError("Android package escaped its channel")
        data = (ROOT.parent / entry["path"]).read_bytes()
        files = build.unpack(data)
        manifest = json.loads(files["floe.json"])
        if (len(data) != entry["size"] or hashlib.sha256(data).hexdigest() != entry["sha256"]
                or build.canonical(files) != entry["contentDigest"]
                or manifest["id"] != identifier or manifest["version"] != version
                or manifest["platforms"] != ["android", "linux"]
                or manifest.get("scriptRuntime") != "none" or manifest.get("pythonPackages", [])
                or any(name.split("/")[0].casefold() == "scripts" for name in files)
                or entry.get("platforms") != ["android"] or entry.get("guideOnly") is not True
                or entry.get("executionVerified") is not False):
            raise ValueError("Android package digest or authored platform policy mismatch")
        build.validate_version(entry["minimumAppVersion"], "minimumAppVersion")
        build.validate_release_notes(entry["releaseNotes"])
    return {entry["id"]: entry for entry in entries}


def run(check=False, staged=False):
    released = verify_released()
    outputs, packages, catalog = candidates()
    for entry in packages:
        old = (released or {}).get(entry["id"])
        if old:
            before, after = (tuple(map(int, item.split("."))) for item in (old["version"], entry["version"]))
            if after < before or (after == before and entry != old):
                raise ValueError("published Android guide version/metadata changed; bump version")
    if staged:
        print("Android guide sources verified; " + ("signed released feed verified" if released else "channel not published"))
        return
    if check:
        if released is None:
            raise ValueError("Android channel is not signed/published")
        for path, data in outputs.items():
            if not path.is_file() or path.read_bytes() != data:
                raise ValueError(f"stale Android artifact: {path.relative_to(ROOT)}")
        return
    key = build.signing_key(False)
    if key is None:
        raise ValueError("Android publication requires the existing Skill Hub signing key")
    outputs[ROOT / "android/catalog.sig"] = build.encoded(dict(
        keyID=build.KEY_ID, signature=base64.b64encode(key.sign(catalog)).decode()))
    for path, data in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.suffix == ".zip" and path.exists():
            continue  # candidates already proved immutable bytes match
        temporary = path.with_name(path.name + ".staging")
        temporary.write_bytes(data)
        temporary.replace(path)
    verify_released()
    print("Signed Android guide channel generated; iOS feed unchanged")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--check", action="store_true")
    modes.add_argument("--check-staged", action="store_true")
    args = parser.parse_args()
    run(check=args.check, staged=args.check_staged)
