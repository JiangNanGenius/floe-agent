#!/usr/bin/env python3
"""Signed content packages (prompts, help, templates, providers, models).

The builder is content-only: it never executes package code. Packages are
deterministic ZIP_STORED archives; the index is canonical JSON signed with a
raw Ed25519 key. This mirrors skill-hub/build.py on purpose so the app's shared
signed-content update core can verify both catalogs the same way.

Modes:
  python3 build.py                 build packages and unsigned index.json
  python3 build.py --sign          refresh generatedAt, sign index.json
  python3 build.py --check         read-only verification of published bytes
  python3 build.py --fixture DIR   write a self-signed fixture under DIR
  python3 build.py --check --fixture DIR
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
import sys
import zipfile

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
PUBLISHER = "JiangNanGenius"
KEY_ID = "official-2026-09"
SCHEMA_VERSION = 1
PATH_PREFIX = "content-hub/"
KINDS = ("prompts", "providers", "models", "help", "templates")
VERSION_PATTERN = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
ID_PATTERN = re.compile(r"[a-z0-9]+(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+\Z")
REVISION_PATTERN = re.compile(r"(?:[0-9a-f]{40})?\Z")
MAX_PACKAGE_BYTES = 8_388_608
MAX_FILES = 128
MAX_ENTRY_BYTES = 2_097_152


class ContentError(ValueError):
    """Any invalid source, index or published artifact."""


def encoded(value):
    """Canonical JSON: sorted keys, compact separators, UTF-8, no escaping."""
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def canonical(files):
    """Length-prefixed SHA-256 over sorted (path, bytes), matching skill-hub."""
    digest = hashlib.sha256()
    for name, data in sorted(files.items()):
        path = name.encode("utf-8")
        digest.update(struct.pack(">Q", len(path)) + path + struct.pack(">Q", len(data)) + data)
    return digest.hexdigest()


def validate_version(value):
    if not isinstance(value, str) or not VERSION_PATTERN.fullmatch(value):
        raise ContentError(f"invalid strict X.Y.Z version: {value!r}")
    return value


def validate_id(value):
    if not isinstance(value, str) or not ID_PATTERN.fullmatch(value):
        raise ContentError(f"invalid stable dotted id: {value!r}")
    return value


def validate_relative_path(name):
    if not isinstance(name, str) or not name or name.startswith("/") or "\\" in name:
        raise ContentError(f"unsafe package path: {name!r}")
    for part in name.split("/"):
        if part in ("", ".", "..") or part.startswith("."):
            raise ContentError(f"unsafe package path: {name!r}")


def validate_release_notes(notes):
    if not isinstance(notes, dict) or any(not isinstance(value, str) for value in notes.values()):
        raise ContentError("releaseNotes must be a localized string dictionary")
    if any(not notes.get(locale, "").strip() for locale in ("zh-Hans", "en")):
        raise ContentError("releaseNotes requires nonempty zh-Hans and en translations")


def validate_string_list(value, field):
    if not isinstance(value, list) or any(not isinstance(item, str) or not item.strip() for item in value):
        raise ContentError(f"{field} must be a list of nonempty strings")
    if len(set(value)) != len(value):
        raise ContentError(f"{field} contains duplicates")


def validate_revision(value):
    if not isinstance(value, str) or not REVISION_PATTERN.fullmatch(value):
        raise ContentError(f"sourceRevision must be empty or 40 lowercase hex characters: {value!r}")
    return value


def package_zip(files):
    """Deterministic archive: ZIP_STORED, 1980 timestamps, fixed permissions."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_STORED) as archive:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data)
    return buffer.getvalue()


def unpack(data):
    files = {}
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for info in archive.infolist():
                if info.is_dir():
                    raise ContentError("package must contain files only")
                name = info.filename
                validate_relative_path(name)
                if name in files:
                    raise ContentError(f"duplicate package entry: {name!r}")
                files[name] = archive.read(info)
    except zipfile.BadZipFile as error:
        raise ContentError("corrupt package archive") from error
    if not files:
        raise ContentError("empty package archive")
    return files


def load_source(kind, folder):
    identifier = validate_id(folder.name)
    files = {}
    for path in sorted(folder.rglob("*")):
        if path.is_symlink():
            raise ContentError(f"symlink in content source: {path}")
        if path.is_file():
            name = path.relative_to(folder).as_posix()
            validate_relative_path(name)
            files[name] = path.read_bytes()
    if len(files) > MAX_FILES or sum(map(len, files.values())) > MAX_PACKAGE_BYTES:
        raise ContentError(f"{identifier}: oversized content package")
    if any(len(data) > MAX_ENTRY_BYTES for data in files.values()):
        raise ContentError(f"{identifier}: a payload file exceeds the per-file limit")
    if "content.json" not in files:
        raise ContentError(f"{identifier}: content.json is required")
    content = json.loads(files["content.json"].decode("utf-8"))
    if not isinstance(content, dict):
        raise ContentError(f"{identifier}: content.json must be an object")
    if content.get("id") != identifier:
        raise ContentError(f"{identifier}: content.json id must match the folder name")
    if content.get("kind") is not None and content["kind"] != kind:
        raise ContentError(f"{identifier}: content.json kind must match its sources/<kind>/ folder")
    schema_version = content.get("schemaVersion")
    if not isinstance(schema_version, int) or isinstance(schema_version, bool) or schema_version < 1:
        raise ContentError(f"{identifier}: content.json schemaVersion must be a positive integer")
    version = validate_version(content.get("version"))
    validate_version(content.get("minimumAppVersion"))
    validate_release_notes(content.get("releaseNotes"))
    required = content.get("requiredCapabilities", [])
    dependencies = content.get("dependencies", [])
    validate_string_list(required, f"{identifier}: requiredCapabilities")
    validate_string_list(dependencies, f"{identifier}: dependencies")
    revision = validate_revision(content.get("sourceRevision", ""))
    contains_scripts = content.get("containsScripts", False)
    if not isinstance(contains_scripts, bool):
        raise ContentError(f"{identifier}: containsScripts must be a boolean")

    archive = package_zip(files)
    relative = f"packages/{identifier}/{version}/{identifier}.zip"
    return dict(
        id=identifier,
        kind=kind,
        version=version,
        schemaVersion=schema_version,
        minimumAppVersion=content["minimumAppVersion"],
        requiredCapabilities=required,
        dependencies=dependencies,
        path=PATH_PREFIX + relative,
        size=len(archive),
        sha256=hashlib.sha256(archive).hexdigest(),
        contentDigest=canonical(files),
        releaseNotes=content["releaseNotes"],
        sourceRevision=revision,
        containsScripts=contains_scripts,
    ), archive


def plan(sources, prefix):
    """Validates sources and returns (entries, {relative path: zip bytes})."""
    entries = []
    packages = {}
    identifiers = set()
    for kind in KINDS:
        kind_dir = sources / kind
        if not kind_dir.is_dir():
            raise ContentError(f"missing sources/{kind} directory")
        for folder in sorted(kind_dir.iterdir()):
            if not folder.is_dir() or folder.is_symlink():
                raise ContentError(f"unexpected entry under sources/{kind}: {folder.name!r}")
            entry, archive = load_source(kind, folder)
            entry["path"] = prefix + entry["path"][len(PATH_PREFIX):]
            if entry["id"] in identifiers:
                raise ContentError(f"duplicate package id: {entry['id']}")
            identifiers.add(entry["id"])
            relative = entry["path"][len(prefix):]
            entries.append(entry)
            packages[relative] = archive
    if not entries:
        raise ContentError("no content sources found")
    entries.sort(key=lambda entry: entry["id"])
    return entries, packages


def write_packages(root, packages, check=False):
    for relative, data in sorted(packages.items()):
        path = root / relative
        if check:
            if not path.is_file() or path.read_bytes() != data:
                raise ContentError(f"published package stale or missing: {path}")
            continue
        if path.exists() and path.read_bytes() != data:
            raise ContentError(f"published version is immutable: {path}; bump the version")
    if not check:
        for relative, data in sorted(packages.items()):
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            if not path.exists():
                path.write_bytes(data)


def now_iso():
    from datetime import datetime, timezone

    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def build_index(entries, root, sign):
    timestamp = None
    index_path = root / "index.json"
    if not sign and index_path.exists():
        try:
            existing = json.loads(index_path.read_bytes())
            timestamp = existing.get("generatedAt")
        except (ValueError, UnicodeDecodeError):
            timestamp = None
    if not isinstance(timestamp, str) or not timestamp:
        timestamp = now_iso()
    return encoded(dict(schemaVersion=SCHEMA_VERSION, publisher=PUBLISHER, generatedAt=timestamp, entries=entries))


def validate_entry(entry, prefix, package_root):
    if not isinstance(entry, dict):
        raise ContentError("index entries must be objects")
    identifier = validate_id(entry.get("id"))
    kind = entry.get("kind")
    if kind not in KINDS:
        raise ContentError(f"{identifier}: invalid kind {kind!r}")
    version = validate_version(entry.get("version"))
    schema_version = entry.get("schemaVersion")
    if not isinstance(schema_version, int) or isinstance(schema_version, bool) or schema_version < 1:
        raise ContentError(f"{identifier}: invalid schemaVersion")
    validate_version(entry.get("minimumAppVersion"))
    validate_string_list(entry.get("requiredCapabilities", []), f"{identifier}: requiredCapabilities")
    validate_string_list(entry.get("dependencies", []), f"{identifier}: dependencies")
    release_notes = entry.get("releaseNotes")
    validate_release_notes(release_notes)
    validate_revision(entry.get("sourceRevision", ""))
    if not isinstance(entry.get("containsScripts"), bool):
        raise ContentError(f"{identifier}: containsScripts must be a boolean")
    expected = prefix + f"packages/{identifier}/{version}/{identifier}.zip"
    if entry.get("path") != expected:
        raise ContentError(f"{identifier}: invalid entry path {entry.get('path')!r}")
    size = entry.get("size")
    if not isinstance(size, int) or isinstance(size, bool) or not 1 <= size <= MAX_PACKAGE_BYTES:
        raise ContentError(f"{identifier}: invalid size")
    for field in ("sha256", "contentDigest"):
        value = entry.get(field)
        if not isinstance(value, str) or len(value) != 64 or any(char not in "0123456789abcdef" for char in value):
            raise ContentError(f"{identifier}: invalid {field}")
    path = package_root / entry["path"]
    if not path.is_file():
        raise ContentError(f"{identifier}: package missing at {path}")
    data = path.read_bytes()
    if len(data) != size:
        raise ContentError(f"{identifier}: package size mismatch")
    if hashlib.sha256(data).hexdigest() != entry["sha256"]:
        raise ContentError(f"{identifier}: package sha256 mismatch")
    if canonical(unpack(data)) != entry["contentDigest"]:
        raise ContentError(f"{identifier}: package contentDigest mismatch")


def verify_signature(payload, envelope, key_record):
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

    if not isinstance(envelope, dict) or set(envelope) != {"keyID", "signature"}:
        raise ContentError("invalid signature envelope")
    if not isinstance(key_record, dict) or envelope.get("keyID") != key_record.get("keyID"):
        raise ContentError("unknown signing key")
    try:
        key = Ed25519PublicKey.from_public_bytes(base64.b64decode(key_record["publicKey"], validate=True))
        proof = base64.b64decode(envelope["signature"], validate=True)
        key.verify(proof, payload)
    except (KeyError, ValueError, InvalidSignature) as error:
        raise ContentError("signature verification failed") from error


def check(root, package_root, prefix, public_key_path):
    index_path = root / "index.json"
    signature_path = root / "index.sig"
    if not index_path.is_file():
        raise ContentError(f"missing {index_path}")
    if not signature_path.is_file():
        raise ContentError("missing index.sig; the coordinator must sign before publishing")
    payload = index_path.read_bytes()
    envelope = json.loads(signature_path.read_bytes())
    key_record = json.loads(Path(public_key_path).read_bytes())
    verify_signature(payload, envelope, key_record)
    index = json.loads(payload)
    if index.get("schemaVersion") != SCHEMA_VERSION or index.get("publisher") != PUBLISHER:
        raise ContentError("invalid index schemaVersion or publisher")
    if not isinstance(index.get("generatedAt"), str) or not index["generatedAt"]:
        raise ContentError("invalid generatedAt")
    entries = index.get("entries")
    if not isinstance(entries, list) or not entries:
        raise ContentError("index entries must be a nonempty list")
    for entry in entries:
        validate_entry(entry, prefix, package_root)
    identifiers = [entry["id"] for entry in entries]
    if len(set(identifiers)) != len(identifiers):
        raise ContentError("duplicate index entries")
    return index


def signing_key():
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    value = os.environ.get("FLOE_CONTENT_HUB_SIGNING_KEY")
    if not value:
        raise ContentError("FLOE_CONTENT_HUB_SIGNING_KEY is required for --sign")
    try:
        return Ed25519PrivateKey.from_private_bytes(base64.b64decode(value, validate=True))
    except ValueError as error:
        raise ContentError("FLOE_CONTENT_HUB_SIGNING_KEY is not a base64 raw Ed25519 key") from error


def public_record(key, key_id):
    from cryptography.hazmat.primitives import serialization

    raw = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return {"keyID": key_id, "publicKey": base64.b64encode(raw).decode()}


def sign_payload(payload, key, key_id):
    return encoded(dict(keyID=key_id, signature=base64.b64encode(key.sign(payload)).decode()))


def build_repo():
    entries, archive = plan(ROOT / "sources", PATH_PREFIX)
    write_packages(ROOT, archive)
    payload = build_index(entries, ROOT, sign=False)
    (ROOT / "index.json").write_bytes(payload)
    signature_path = ROOT / "index.sig"
    if signature_path.is_file():
        try:
            verify_signature(payload, json.loads(signature_path.read_bytes()),
                             json.loads((ROOT / "public-key.json").read_bytes()))
        except (ValueError, ContentError):
            print("warning: index.sig is stale; re-run --sign before publishing", file=sys.stderr)
    print(f"Built {len(entries)} content packages and unsigned index.json")


def sign_repo():
    key = signing_key()
    pinned = json.loads((ROOT / "public-key.json").read_bytes())
    if pinned.get("keyID") != KEY_ID or public_record(key, KEY_ID) != pinned:
        raise ContentError("signing key does not match the pinned content-hub public identity")
    entries, archive = plan(ROOT / "sources", PATH_PREFIX)
    write_packages(ROOT, archive)
    payload = build_index(entries, ROOT, sign=True)
    (ROOT / "index.json").write_bytes(payload)
    (ROOT / "index.sig").write_bytes(sign_payload(payload, key, KEY_ID))
    print(f"Signed index.json for {len(entries)} content packages")


def ensure_fixture_location(destination):
    resolved = destination.resolve()
    repository = REPO.resolve()
    try:
        resolved.relative_to(repository)
    except ValueError:
        return
    try:
        resolved.relative_to(repository / "Local")
    except ValueError:
        raise ContentError("fixture directories inside the repository must live under Local/") from None


def make_fixture(destination):
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    destination = Path(destination)
    ensure_fixture_location(destination)
    if destination.exists() and any(destination.iterdir()):
        raise ContentError("fixture directory must be empty or absent")
    key = Ed25519PrivateKey.generate()
    entries, archive = plan(ROOT / "sources", "")
    write_packages(destination, archive)
    payload = build_index(entries, destination, sign=True)
    (destination / "index.json").write_bytes(payload)
    (destination / "index.sig").write_bytes(sign_payload(payload, key, "fixture-local"))
    (destination / "public-key.json").write_bytes(encoded(public_record(key, "fixture-local")))
    private_path = destination / "signing-key.b64"
    raw = key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
    private_path.write_bytes(base64.b64encode(raw))
    os.chmod(private_path, 0o600)
    record = public_record(key, "fixture-local")
    print(f"Wrote signed fixture to {destination}")
    print(f"fixture keyID={record['keyID']} publicKey={record['publicKey']}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sign", action="store_true", help="sign index.json with FLOE_CONTENT_HUB_SIGNING_KEY")
    parser.add_argument("--check", action="store_true", help="read-only verification; exit 1 on mismatch")
    parser.add_argument("--fixture", metavar="DIR", help="write or verify a self-signed fixture")
    args = parser.parse_args(argv)
    try:
        if args.sign and args.fixture:
            raise ContentError("--sign and --fixture cannot be combined")
        if args.sign and args.check:
            raise ContentError("--sign and --check cannot be combined")
        if args.fixture:
            destination = Path(args.fixture)
            if args.check:
                check(destination, destination, "", destination / "public-key.json")
                print(f"Verified signed fixture at {destination}")
            else:
                make_fixture(destination)
        elif args.check:
            check(ROOT, REPO, PATH_PREFIX, ROOT / "public-key.json")
            print("Verified signed content-hub index and packages")
        elif args.sign:
            sign_repo()
        else:
            build_repo()
    except (ContentError, OSError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
