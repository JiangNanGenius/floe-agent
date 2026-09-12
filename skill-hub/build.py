#!/usr/bin/env python3
"""Reproducible official packages. No package code is executed by this builder.

--bootstrap migrates the three existing Swift guide definitions once.
--provision-key creates a signing key directly in the repository Actions secret;
only its public key is written to the working tree. Never prints private bytes.
Normal signed publication reads FLOE_SKILL_HUB_SIGNING_KEY (base64 raw Ed25519).
"""
import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
SWIFT = REPO / "FloeAgent/Sources/FloeSkills"
IDS = ("floe-pdf", "floe-office", "floe-network", "floe-video")
KEY_ID = "official-2026-09"


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def canonical(files):
    digest = hashlib.sha256()
    for name, data in sorted(files.items()):
        path = name.encode()
        digest.update(struct.pack(">Q", len(path)) + path + struct.pack(">Q", len(data)) + data)
    return digest.hexdigest()


def bootstrap():
    path = SWIFT / "BundledDomainSkills.swift"
    source = path.read_text()
    pattern = re.compile(r'        Definition\(\n            id: "(floe-(?:pdf|office|network))",\n            name: "([^"]+)",\n            description: "([^"]+)",\n            version: "([^"]+)",\n            exposed: true,\n            markdown: """\n(.*?)\n            """\n        \),\n', re.S)
    definitions = pattern.findall(source)
    if len(definitions) != 3:
        raise ValueError("bootstrap requires exactly three original exposed definitions")
    for skill_id, name, description, _, body in definitions:
        folder = ROOT / "sources" / skill_id
        folder.mkdir(parents=True, exist_ok=False)
        body = "\n".join(line[12:] if line.startswith(" " * 12) else line for line in body.splitlines())
        (folder / "SKILL.md").write_text(f"---\nname: {skill_id}\ndisplay_name: {name}\ndescription: {description}\n---\n\n{body}")
        (folder / "floe.json").write_bytes(encoded(dict(schemaVersion=1, id=skill_id, version="1.1.0", capabilities=[], tools=[], platforms=["ios"], scriptRuntime="none", pythonPackages=[])))
        (folder / "release.json").write_bytes(encoded(dict(name=name, description=description, minimumAppVersion="1.4.98", releaseNotes={"zh-Hans": "迁移至唯一官方签名 ZIP 更新源。", "en": "Move to the exclusive official signed ZIP update source."})))
    source = pattern.sub("", source).replace("public static let all: [Definition] = [", "public static let all: [Definition] = officialDefinitions + [")
    path.write_text(source)


def signing_key(provision):
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives import serialization
    if provision:
        if (ROOT / "public-key.json").exists():
            raise ValueError("refusing to rotate an existing signing identity")
        key = Ed25519PrivateKey.generate()
        raw = key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
        subprocess.run(["gh", "secret", "set", "FLOE_SKILL_HUB_SIGNING_KEY", "--repo", "JiangNanGenius/floe-agent"], input=base64.b64encode(raw), check=True)
    else:
        value = os.environ.get("FLOE_SKILL_HUB_SIGNING_KEY")
        if not value:
            return None
        key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(value, validate=True))
    public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    record = {"keyID": KEY_ID, "publicKey": base64.b64encode(public).decode()}
    path = ROOT / "public-key.json"
    if path.exists() and json.loads(path.read_bytes()) != record:
        raise ValueError("signing key does not match pinned public identity")
    if provision:
        path.write_bytes(encoded(record))
    return key


def validate_release(release):
    """Match the app catalog contract before generating or signing artifacts."""
    if not isinstance(release, dict):
        raise ValueError("release metadata must be an object")
    version = release.get("minimumAppVersion")
    if not isinstance(version, str) or not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version):
        raise ValueError("invalid minimumAppVersion")
    notes = release.get("releaseNotes")
    if not isinstance(notes, dict) or any(not isinstance(value, str) for value in notes.values()):
        raise ValueError("releaseNotes must be a localized string dictionary")
    if any(not notes.get(locale, "").strip() for locale in ("zh-Hans", "en")):
        raise ValueError("releaseNotes requires nonempty zh-Hans and en translations")
    if any(not isinstance(release.get(field), str) or not release[field].strip() for field in ("name", "description")):
            raise ValueError("release metadata requires name and description")


def validate_guide_metadata(markdown, manifest, release):
    """Official source guides use a small, unquoted frontmatter contract.

    Reject drift before signing: the app uses release metadata in discovery,
    while installed packages use SKILL.md. They must describe the same guide.
    This is not the general third-party skill Markdown parser.
    """
    match = re.match(r"\A---\r?\n(.*?)\r?\n---(?:\r?\n|\Z)", markdown, re.S)
    if not match:
        raise ValueError("official guide requires frontmatter")
    values = {}
    for line in match[1].splitlines():
        field, separator, value = line.partition(":")
        if not separator or field in values:
            raise ValueError("invalid or duplicate official guide metadata")
        values[field] = value.strip()
    expected = {"name": manifest["id"], "display_name": release["name"], "description": release["description"]}
    if values != expected:
        raise ValueError("official guide metadata differs from its manifest or release description")


def load_models():
    """Loads and validates the floe-video model catalog (catalog v2 `models`).

    Ready entries must carry https URLs, 64-hex SHA-256 and positive sizes;
    license-check entries stay staged until a human confirms the license.
    """
    allowed = {"MIT", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0", "ISC", "MPL-2.0",
               "EPL-1.0", "0BSD", "Zlib", "CC0-1.0", "Unlicense", "Public-Domain"}
    rejected = {"GPL", "GPL-2.0", "GPL-3.0", "LGPL", "LGPL-2.1", "LGPL-3.0", "AGPL-3.0", "S-Lab", "CC-BY-NC", "CC-BY-NC-4.0"}
    path = ROOT / "models.json"
    if not path.exists():
        return []
    payload = json.loads(path.read_bytes())
    models = payload.get("models", [])
    seen = set()
    for model in models:
        identifier = model.get("id")
        if not identifier or identifier in seen:
            raise ValueError(f"invalid or duplicate model id: {identifier!r}")
        seen.add(identifier)
        if model.get("skillID") != "floe-video":
            raise ValueError(f"{identifier}: models must belong to floe-video")
        if not model.get("capability"):
            raise ValueError(f"{identifier}: capability is required")
        license_name = model.get("license")
        status = model.get("status", "pending-assets")
        if status == "excluded":
            if model.get("files") or not model.get("notes"):
                raise ValueError(f"{identifier}: excluded entries require a reason and no downloadable files")
            continue
        if license_name in rejected:
            raise ValueError(f"{identifier}: rejected license {license_name}")
        if status not in {"ready", "pending-assets", "license-check"}:
            raise ValueError(f"{identifier}: unknown status {status}")
        if status == "ready":
            if license_name not in allowed:
                raise ValueError(f"{identifier}: ready models need an allowed license")
            files = model.get("files") or []
            if not files:
                raise ValueError(f"{identifier}: ready models need files")
            for entry in files:
                if not str(entry.get("url", "")).startswith("https://"):
                    raise ValueError(f"{identifier}: file URL must be https")
                sha = entry.get("sha256", "")
                if len(sha) != 64 or any(c not in "0123456789abcdefABCDEF" for c in sha):
                    raise ValueError(f"{identifier}: file sha256 must be 64 hex characters")
                size = entry.get("sizeBytes")
                if not isinstance(size, int) or size <= 0:
                    raise ValueError(f"{identifier}: file sizeBytes must be positive")
    return models


def build(check, key):
    outputs = {}
    packages = []
    definitions = []
    seed_files = []
    for skill_id in IDS:
        folder = ROOT / "sources" / skill_id
        files = {}
        for path in sorted(folder.rglob("*")):
            if path.is_symlink():
                raise ValueError("symlink in skill source")
            if path.is_file() and path.name != "release.json":
                files[path.relative_to(folder).as_posix()] = path.read_bytes()
        if len(files) > 128 or sum(map(len, files.values())) > 8_388_608:
            raise ValueError("oversized skill")
        # The three app-bundled guides stay lightweight. Preserve exact bytes
        # (including newlines) rather than reconstructing signed package files.
        if sum(map(len, files.values())) > 262_144:
            raise ValueError("bundled official guide exceeds 256 KiB")
        seed_files.append("        " + json.dumps(skill_id) + ": [" + ", ".join(json.dumps(name) + ": Data(base64Encoded: " + json.dumps(base64.b64encode(data).decode()) + ")!" for name, data in files.items()) + "]")
        manifest = json.loads(files["floe.json"])
        release = json.loads((folder / "release.json").read_bytes())
        validate_release(release)
        validate_guide_metadata(files["SKILL.md"].decode(), manifest, release)
        version = manifest["version"]
        if manifest["id"] != skill_id or not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version):
            raise ValueError("invalid package identity/version")
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_STORED) as archive:
            for name, data in sorted(files.items()):
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = 0o100644 << 16
                archive.writestr(info, data)
        data = buffer.getvalue()
        relative = f"packages/{skill_id}/{version}/{skill_id}.zip"
        old = ROOT / relative
        if old.exists() and old.read_bytes() != data:
            raise ValueError(f"immutable version changed: {relative}; bump the version")
        outputs[old] = data
        packages.append(dict(id=skill_id, version=version, path="skill-hub/" + relative, size=len(data), sha256=hashlib.sha256(data).hexdigest(), contentDigest=canonical(files), minimumAppVersion=release["minimumAppVersion"], releaseNotes=release["releaseNotes"]))
        body = files["SKILL.md"].decode().split("---", 2)[2].lstrip("\n")
        # JSON escaping is also valid for these Swift string literals.
        literal = lambda value: json.dumps(value, ensure_ascii=False).replace('\\/', '/')
        definitions.append("        Definition(id: " + literal(skill_id) + ", name: " + literal(release["name"]) + ", description: " + literal(release["description"]) + ", version: " + literal(version) + ", exposed: true, markdown: " + literal(body) + ")")
    models = load_models()
    catalog = encoded(dict(schemaVersion=2, publisher="JiangNanGenius", packages=packages, models=models))
    outputs[ROOT / "catalog.json"] = catalog
    digests = ",\n".join("        " + json.dumps(p["id"]) + ": " + json.dumps(p["contentDigest"]) for p in packages)
    outputs[SWIFT / "OfficialBundledSkills.generated.swift"] = ("// Generated by skill-hub/build.py; edit skill-hub/sources instead.\nimport Foundation\n\nextension BundledDomainSkills {\n    static let officialDefinitions: [Definition] = [\n" + ",\n".join(definitions) + "\n    ]\n    public static let officialPackageDigests: [String: String] = [\n" + digests + "\n    ]\n    public static let officialSeedFiles: [String: [String: Data]] = [\n" + ",\n".join(seed_files) + "\n    ]\n}\n").encode()
    public = json.loads((ROOT / "public-key.json").read_bytes())
    outputs[SWIFT / "OfficialSkillHubKeys.generated.swift"] = ("// Generated trust root. Changes require an app release.\nimport Foundation\n\nextension OfficialSkillHub {\n    public static let trustedKeys: [String: Data] = [\n        " + json.dumps(public["keyID"]) + ": Data(base64Encoded: " + json.dumps(public["publicKey"]) + ")!\n    ]\n}\n").encode()
    if key:
        outputs[ROOT / "catalog.sig"] = encoded(dict(keyID=KEY_ID, signature=base64.b64encode(key.sign(catalog)).decode()))
    else:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
        signature = json.loads((ROOT / "catalog.sig").read_bytes())
        if signature["keyID"] != public["keyID"]:
            raise ValueError("unknown signing key")
        Ed25519PublicKey.from_public_bytes(base64.b64decode(public["publicKey"])).verify(base64.b64decode(signature["signature"]), catalog)
    for path, data in outputs.items():
        if check:
            if not path.exists() or path.read_bytes() != data:
                raise ValueError(f"generated artifact stale: {path.relative_to(REPO)}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    print("Verified official packages, signatures and generated app definitions" if check else "Built official packages and generated app definitions")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--bootstrap", action="store_true")
    parser.add_argument("--provision-key", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.bootstrap:
        bootstrap()
    build(args.check, signing_key(args.provision_key))
